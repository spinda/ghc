{-# LANGUAGE CPP #-}

-------------------------------------------------------------------------------
--
-- | Dynamic flags
--
-- Most flags are dynamic flags, which means they can change from compilation
-- to compilation using @OPTIONS_GHC@ pragmas, and in a multi-session GHC each
-- session can be using different dynamic flags. Dynamic flags can also be set
-- at the prompt in GHCi.
--
-- (c) The University of Glasgow 2005
--
-------------------------------------------------------------------------------

{-# OPTIONS_GHC -fno-cse #-}
-- -fno-cse is needed for GLOBAL_VAR's to behave properly

module DynFlags (
        -- * Dynamic flags and associated configuration types
        DumpFlag(..),
        GeneralFlag(..),
        WarningFlag(..),
        ExtensionFlag(..),
        Language(..),
        PlatformConstants(..),
        FatalMessager, LogAction, FlushOut(..), FlushErr(..),
        ProfAuto(..),
        glasgowExtsFlags,
        dopt, dopt_set, dopt_unset,
        gopt, gopt_set, gopt_unset,
        wopt, wopt_set, wopt_unset,
        xopt, xopt_set, xopt_unset,
        lang_set,
        useUnicodeSyntax,
        whenGeneratingDynamicToo, ifGeneratingDynamicToo,
        whenCannotGenerateDynamicToo,
        dynamicTooMkDynamicDynFlags,
        DynFlags(..),
        FlagSpec(..),
        HasDynFlags(..), ContainsDynFlags(..),
        RtsOptsEnabled(..),
        HscTarget(..), isObjectTarget, defaultObjectTarget,
        targetRetainsAllBindings,
        GhcMode(..), isOneShot,
        GhcLink(..), isNoLink,
        PackageFlag(..), PackageArg(..), ModRenaming(..),
        PkgConfRef(..),
        Option(..), showOpt,
        DynLibLoader(..),
        fFlags, fWarningFlags, fLangFlags, xFlags,
        dynFlagDependencies,
        tablesNextToCode, mkTablesNextToCode,
        SigOf, getSigOf,
        checkOptLevel,

        Way(..), mkBuildTag, wayRTSOnly, addWay', updateWays,
        wayGeneralFlags, wayUnsetGeneralFlags,

        -- ** Safe Haskell
        SafeHaskellMode(..),
        safeHaskellOn, safeImportsOn, safeLanguageOn, safeInferOn,
        packageTrustOn,
        safeDirectImpsReq, safeImplicitImpsReq,
        unsafeFlags, unsafeFlagsForInfer,

        -- ** System tool settings and locations
        Settings(..),
        targetPlatform, programName, projectVersion,
        ghcUsagePath, ghciUsagePath, topDir, tmpDir, rawSettings,
        versionedAppDir,
        extraGccViaCFlags, systemPackageConfig,
        pgm_L, pgm_P, pgm_F, pgm_c, pgm_s, pgm_a, pgm_l, pgm_dll, pgm_T,
        pgm_sysman, pgm_windres, pgm_libtool, pgm_lo, pgm_lc,
        opt_L, opt_P, opt_F, opt_c, opt_a, opt_l,
        opt_windres, opt_lo, opt_lc,


        -- ** Manipulating DynFlags
        defaultDynFlags,                -- Settings -> DynFlags
        defaultWays,
        interpWays,
        initDynFlags,                   -- DynFlags -> IO DynFlags
        defaultFatalMessager,
        defaultLogAction,
        defaultLogActionHPrintDoc,
        defaultLogActionHPutStrDoc,
        defaultFlushOut,
        defaultFlushErr,

        getOpts,                        -- DynFlags -> (DynFlags -> [a]) -> [a]
        getVerbFlags,
        updOptLevel,
        setTmpDir,
        setPackageKey,
        interpretPackageEnv,

        -- ** Parsing DynFlags
        parseDynamicFlagsCmdLine,
        parseDynamicFilePragma,
        parseDynamicFlagsFull,

        -- ** Available DynFlags
        allFlags,
        flagsAll,
        flagsDynamic,
        flagsPackage,
        flagsForCompletion,

        supportedLanguagesAndExtensions,
        languageExtensions,

        -- ** DynFlags C compiler options
        picCCOpts, picPOpts,

        -- * Configuration of the stg-to-stg passes
        StgToDo(..),
        getStgToDo,

        -- * Compiler configuration suitable for display to the user
        compilerInfo,

#ifdef GHCI
        rtsIsProfiled,
#endif
        dynamicGhc,

#include "../includes/dist-derivedconstants/header/GHCConstantsHaskellExports.hs"
        bLOCK_SIZE_W,
        wORD_SIZE_IN_BITS,
        tAG_MASK,
        mAX_PTR_TAG,
        tARGET_MIN_INT, tARGET_MAX_INT, tARGET_MAX_WORD,

        unsafeGlobalDynFlags, setUnsafeGlobalDynFlags,

        -- * SSE and AVX
        isSseEnabled,
        isSse2Enabled,
        isSse4_2Enabled,
        isAvxEnabled,
        isAvx2Enabled,
        isAvx512cdEnabled,
        isAvx512erEnabled,
        isAvx512fEnabled,
        isAvx512pfEnabled,

        -- * Linker/compiler information
        LinkerInfo(..),
        CompilerInfo(..),
  ) where

#include "HsVersions.h"

import Platform
import PlatformConstants
import Module
import PackageConfig
import {-# SOURCE #-} Hooks
import {-# SOURCE #-} PrelNames ( mAIN )
import {-# SOURCE #-} Packages (PackageState, emptyPackageState)
import DriverPhases     ( Phase(..), phaseInputExt )
import Config
import CmdLineParser
import Constants
import Panic
import Util
import Maybes
import MonadUtils
import qualified Pretty
import SrcLoc
import BasicTypes       ( IntWithInf, treatZeroAsInf )
import FastString
import Outputable
#ifdef GHCI
import Foreign.C        ( CInt(..) )
import System.IO.Unsafe ( unsafeDupablePerformIO )
#endif
import {-# SOURCE #-} ErrUtils ( Severity(..), MsgDoc, mkLocMessage )

import System.IO.Unsafe ( unsafePerformIO )
import Data.IORef
import Control.Arrow ((&&&))
import Control.Monad
import Control.Exception (throwIO)

import Data.Bits
import Data.Char
import Data.Int
import Data.List
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Word
import System.FilePath
import System.Directory
import System.Environment (getEnv)
import System.IO
import System.IO.Error
import Text.ParserCombinators.ReadP hiding (char)
import Text.ParserCombinators.ReadP as R

import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet

import GHC.Foreign (withCString, peekCString)

-- Note [Updating flag description in the User's Guide]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- If you modify anything in this file please make sure that your changes are
-- described in the User's Guide. Usually at least two sections need to be
-- updated:
--
--  * Flag Reference section in docs/users-guide/flags.xml lists all available
--    flags together with a short description
--
--  * Flag description in docs/users_guide/using.xml provides a detailed
--    explanation of flags' usage.

-- Note [Supporting CLI completion]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- The command line interface completion (in for example bash) is an easy way
-- for the developer to learn what flags are available from GHC.
-- GHC helps by separating which flags are available when compiling with GHC,
-- and which flags are available when using GHCi.
-- A flag is assumed to either work in both these modes, or only in one of them.
-- When adding or changing a flag, please consider for which mode the flag will
-- have effect, and annotate it accordingly. For Flags use defFlag, defGhcFlag,
-- defGhciFlag, and for FlagSpec use flagSpec or flagGhciSpec.

-- -----------------------------------------------------------------------------
-- DynFlags

data DumpFlag
-- See Note [Updating flag description in the User's Guide]

   -- debugging flags
   = Opt_D_dump_cmm
   | Opt_D_dump_cmm_raw
   -- All of the cmm subflags (there are a lot!)  Automatically
   -- enabled if you run -ddump-cmm
   | Opt_D_dump_cmm_cfg
   | Opt_D_dump_cmm_cbe
   | Opt_D_dump_cmm_switch
   | Opt_D_dump_cmm_proc
   | Opt_D_dump_cmm_sink
   | Opt_D_dump_cmm_sp
   | Opt_D_dump_cmm_procmap
   | Opt_D_dump_cmm_split
   | Opt_D_dump_cmm_info
   | Opt_D_dump_cmm_cps
   -- end cmm subflags
   | Opt_D_dump_asm
   | Opt_D_dump_asm_native
   | Opt_D_dump_asm_liveness
   | Opt_D_dump_asm_regalloc
   | Opt_D_dump_asm_regalloc_stages
   | Opt_D_dump_asm_conflicts
   | Opt_D_dump_asm_stats
   | Opt_D_dump_asm_expanded
   | Opt_D_dump_llvm
   | Opt_D_dump_core_stats
   | Opt_D_dump_deriv
   | Opt_D_dump_ds
   | Opt_D_dump_foreign
   | Opt_D_dump_inlinings
   | Opt_D_dump_rule_firings
   | Opt_D_dump_rule_rewrites
   | Opt_D_dump_simpl_trace
   | Opt_D_dump_occur_anal
   | Opt_D_dump_parsed
   | Opt_D_dump_rn
   | Opt_D_dump_simpl
   | Opt_D_dump_simpl_iterations
   | Opt_D_dump_spec
   | Opt_D_dump_prep
   | Opt_D_dump_stg
   | Opt_D_dump_call_arity
   | Opt_D_dump_stranal
   | Opt_D_dump_strsigs
   | Opt_D_dump_tc
   | Opt_D_dump_types
   | Opt_D_dump_rules
   | Opt_D_dump_cse
   | Opt_D_dump_worker_wrapper
   | Opt_D_dump_rn_trace
   | Opt_D_dump_rn_stats
   | Opt_D_dump_opt_cmm
   | Opt_D_dump_simpl_stats
   | Opt_D_dump_cs_trace -- Constraint solver in type checker
   | Opt_D_dump_tc_trace
   | Opt_D_dump_if_trace
   | Opt_D_dump_vt_trace
   | Opt_D_dump_splices
   | Opt_D_th_dec_file
   | Opt_D_dump_BCOs
   | Opt_D_dump_vect
   | Opt_D_dump_ticked
   | Opt_D_dump_rtti
   | Opt_D_source_stats
   | Opt_D_verbose_stg2stg
   | Opt_D_dump_hi
   | Opt_D_dump_hi_diffs
   | Opt_D_dump_mod_cycles
   | Opt_D_dump_mod_map
   | Opt_D_dump_view_pattern_commoning
   | Opt_D_verbose_core2core
   | Opt_D_dump_debug

   deriving (Eq, Show, Enum)

-- | Enumerates the simple on-or-off dynamic flags
data GeneralFlag
-- See Note [Updating flag description in the User's Guide]

   = Opt_DumpToFile                     -- ^ Append dump output to files instead of stdout.
   | Opt_D_faststring_stats
   | Opt_D_dump_minimal_imports
   | Opt_DoCoreLinting
   | Opt_DoStgLinting
   | Opt_DoCmmLinting
   | Opt_DoAsmLinting
   | Opt_DoAnnotationLinting
   | Opt_NoLlvmMangler                 -- hidden flag

   | Opt_WarnIsError                    -- -Werror; makes warnings fatal

   | Opt_PrintExplicitForalls
   | Opt_PrintExplicitKinds
   | Opt_PrintUnicodeSyntax

   -- optimisation opts
   | Opt_CallArity
   | Opt_Strictness
   | Opt_LateDmdAnal
   | Opt_KillAbsence
   | Opt_KillOneShot
   | Opt_FullLaziness
   | Opt_FloatIn
   | Opt_Specialise
   | Opt_SpecialiseAggressively
   | Opt_CrossModuleSpecialise
   | Opt_StaticArgumentTransformation
   | Opt_CSE
   | Opt_LiberateCase
   | Opt_SpecConstr
   | Opt_DoLambdaEtaExpansion
   | Opt_IgnoreAsserts
   | Opt_DoEtaReduction
   | Opt_CaseMerge
   | Opt_UnboxStrictFields
   | Opt_UnboxSmallStrictFields
   | Opt_DictsCheap
   | Opt_EnableRewriteRules             -- Apply rewrite rules during simplification
   | Opt_Vectorise
   | Opt_VectorisationAvoidance
   | Opt_RegsGraph                      -- do graph coloring register allocation
   | Opt_RegsIterative                  -- do iterative coalescing graph coloring register allocation
   | Opt_PedanticBottoms                -- Be picky about how we treat bottom
   | Opt_LlvmTBAA                       -- Use LLVM TBAA infastructure for improving AA (hidden flag)
   | Opt_LlvmPassVectorsInRegisters     -- Pass SIMD vectors in registers (requires a patched LLVM) (hidden flag)
   | Opt_IrrefutableTuples
   | Opt_CmmSink
   | Opt_CmmElimCommonBlocks
   | Opt_OmitYields
   | Opt_SimpleListLiterals
   | Opt_FunToThunk               -- allow WwLib.mkWorkerArgs to remove all value lambdas
   | Opt_DictsStrict                     -- be strict in argument dictionaries
   | Opt_DmdTxDictSel              -- use a special demand transformer for dictionary selectors
   | Opt_Loopification                  -- See Note [Self-recursive tail calls]

   -- Interface files
   | Opt_IgnoreInterfacePragmas
   | Opt_OmitInterfacePragmas
   | Opt_ExposeAllUnfoldings
   | Opt_WriteInterface -- forces .hi files to be written even with -fno-code

   -- profiling opts
   | Opt_AutoSccsOnIndividualCafs
   | Opt_ProfCountEntries

   -- misc opts
   | Opt_Pp
   | Opt_ForceRecomp
   | Opt_ExcessPrecision
   | Opt_EagerBlackHoling
   | Opt_NoHsMain
   | Opt_SplitObjs
   | Opt_StgStats
   | Opt_HideAllPackages
   | Opt_PrintBindResult
   | Opt_Haddock
   | Opt_HaddockOptions
   | Opt_BreakOnException
   | Opt_BreakOnError
   | Opt_PrintEvldWithShow
   | Opt_PrintBindContents
   | Opt_GenManifest
   | Opt_EmbedManifest
   | Opt_SharedImplib
   | Opt_BuildingCabalPackage
   | Opt_IgnoreDotGhci
   | Opt_GhciSandbox
   | Opt_GhciHistory
   | Opt_HelpfulErrors
   | Opt_DeferTypeErrors
   | Opt_DeferTypedHoles
   | Opt_Parallel
   | Opt_PIC
   | Opt_SccProfilingOn
   | Opt_Ticky
   | Opt_Ticky_Allocd
   | Opt_Ticky_LNE
   | Opt_Ticky_Dyn_Thunk
   | Opt_Static
   | Opt_RPath
   | Opt_RelativeDynlibPaths
   | Opt_Hpc
   | Opt_FlatCache

   -- PreInlining is on by default. The option is there just to see how
   -- bad things get if you turn it off!
   | Opt_SimplPreInlining

   -- output style opts
   | Opt_ErrorSpans -- Include full span info in error messages,
                    -- instead of just the start position.
   | Opt_PprCaseAsLet
   | Opt_PprShowTicks

   -- Suppress all coercions, them replacing with '...'
   | Opt_SuppressCoercions
   | Opt_SuppressVarKinds
   -- Suppress module id prefixes on variables.
   | Opt_SuppressModulePrefixes
   -- Suppress type applications.
   | Opt_SuppressTypeApplications
   -- Suppress info such as arity and unfoldings on identifiers.
   | Opt_SuppressIdInfo
   -- Suppress separate type signatures in core, but leave types on
   -- lambda bound vars
   | Opt_SuppressTypeSignatures
   -- Suppress unique ids on variables.
   -- Except for uniques, as some simplifier phases introduce new
   -- variables that have otherwise identical names.
   | Opt_SuppressUniques

   -- temporary flags
   | Opt_AutoLinkPackages
   | Opt_ImplicitImportQualified

   -- keeping stuff
   | Opt_KeepHiDiffs
   | Opt_KeepHcFiles
   | Opt_KeepSFiles
   | Opt_KeepTmpFiles
   | Opt_KeepRawTokenStream
   | Opt_KeepLlvmFiles

   | Opt_BuildDynamicToo

   -- safe haskell flags
   | Opt_DistrustAllPackages
   | Opt_PackageTrust

   -- debugging flags
   | Opt_Debug

   deriving (Eq, Show, Enum)

data WarningFlag =
-- See Note [Updating flag description in the User's Guide]
     Opt_WarnDuplicateExports
   | Opt_WarnDuplicateConstraints
   | Opt_WarnRedundantConstraints
   | Opt_WarnHiShadows
   | Opt_WarnImplicitPrelude
   | Opt_WarnIncompletePatterns
   | Opt_WarnIncompleteUniPatterns
   | Opt_WarnIncompletePatternsRecUpd
   | Opt_WarnOverflowedLiterals
   | Opt_WarnEmptyEnumerations
   | Opt_WarnMissingFields
   | Opt_WarnMissingImportList
   | Opt_WarnMissingMethods
   | Opt_WarnMissingSigs
   | Opt_WarnMissingLocalSigs
   | Opt_WarnNameShadowing
   | Opt_WarnOverlappingPatterns
   | Opt_WarnTypeDefaults
   | Opt_WarnMonomorphism
   | Opt_WarnUnusedTopBinds
   | Opt_WarnUnusedLocalBinds
   | Opt_WarnUnusedPatternBinds
   | Opt_WarnUnusedImports
   | Opt_WarnUnusedMatches
   | Opt_WarnContextQuantification
   | Opt_WarnWarningsDeprecations
   | Opt_WarnDeprecatedFlags
   | Opt_WarnAMP
   | Opt_WarnDodgyExports
   | Opt_WarnDodgyImports
   | Opt_WarnOrphans
   | Opt_WarnAutoOrphans
   | Opt_WarnIdentities
   | Opt_WarnTabs
   | Opt_WarnUnrecognisedPragmas
   | Opt_WarnDodgyForeignImports
   | Opt_WarnUnusedDoBind
   | Opt_WarnWrongDoBind
   | Opt_WarnAlternativeLayoutRuleTransitional
   | Opt_WarnUnsafe
   | Opt_WarnSafe
   | Opt_WarnTrustworthySafe
   | Opt_WarnPointlessPragmas
   | Opt_WarnUnsupportedCallingConventions
   | Opt_WarnUnsupportedLlvmVersion
   | Opt_WarnInlineRuleShadowing
   | Opt_WarnTypedHoles
   | Opt_WarnPartialTypeSignatures
   | Opt_WarnMissingExportedSigs
   | Opt_WarnUntickedPromotedConstructors
   | Opt_WarnDerivingTypeable
   | Opt_WarnDeferredTypeErrors
   deriving (Eq, Show, Enum)

data Language = Haskell98 | Haskell2010
   deriving Enum

-- | The various Safe Haskell modes
data SafeHaskellMode
   = Sf_None
   | Sf_Unsafe
   | Sf_Trustworthy
   | Sf_Safe
   deriving (Eq)

instance Show SafeHaskellMode where
    show Sf_None         = "None"
    show Sf_Unsafe       = "Unsafe"
    show Sf_Trustworthy  = "Trustworthy"
    show Sf_Safe         = "Safe"

instance Outputable SafeHaskellMode where
    ppr = text . show

data ExtensionFlag
-- See Note [Updating flag description in the User's Guide]
   = Opt_Cpp
   | Opt_OverlappingInstances
   | Opt_UndecidableInstances
   | Opt_IncoherentInstances
   | Opt_MonomorphismRestriction
   | Opt_MonoPatBinds
   | Opt_MonoLocalBinds
   | Opt_RelaxedPolyRec           -- Deprecated
   | Opt_ExtendedDefaultRules     -- Use GHC's extended rules for defaulting
   | Opt_ForeignFunctionInterface
   | Opt_UnliftedFFITypes
   | Opt_InterruptibleFFI
   | Opt_CApiFFI
   | Opt_GHCForeignImportPrim
   | Opt_JavaScriptFFI
   | Opt_ParallelArrays           -- Syntactic support for parallel arrays
   | Opt_Arrows                   -- Arrow-notation syntax
   | Opt_TemplateHaskell
   | Opt_QuasiQuotes
   | Opt_ImplicitParams
   | Opt_ImplicitPrelude
   | Opt_ScopedTypeVariables
   | Opt_AllowAmbiguousTypes
   | Opt_UnboxedTuples
   | Opt_BangPatterns
   | Opt_TypeFamilies
   | Opt_OverloadedStrings
   | Opt_OverloadedLists
   | Opt_NumDecimals
   | Opt_DisambiguateRecordFields
   | Opt_RecordWildCards
   | Opt_RecordPuns
   | Opt_ViewPatterns
   | Opt_GADTs
   | Opt_GADTSyntax
   | Opt_NPlusKPatterns
   | Opt_DoAndIfThenElse
   | Opt_RebindableSyntax
   | Opt_ConstraintKinds
   | Opt_PolyKinds                -- Kind polymorphism
   | Opt_DataKinds                -- Datatype promotion
   | Opt_InstanceSigs

   | Opt_StandaloneDeriving
   | Opt_DeriveDataTypeable
   | Opt_AutoDeriveTypeable       -- Automatic derivation of Typeable
   | Opt_DeriveFunctor
   | Opt_DeriveTraversable
   | Opt_DeriveFoldable
   | Opt_DeriveGeneric            -- Allow deriving Generic/1
   | Opt_DefaultSignatures        -- Allow extra signatures for defmeths
   | Opt_DeriveAnyClass           -- Allow deriving any class

   | Opt_TypeSynonymInstances
   | Opt_FlexibleContexts
   | Opt_FlexibleInstances
   | Opt_ConstrainedClassMethods
   | Opt_MultiParamTypeClasses
   | Opt_NullaryTypeClasses
   | Opt_FunctionalDependencies
   | Opt_UnicodeSyntax
   | Opt_ExistentialQuantification
   | Opt_MagicHash
   | Opt_EmptyDataDecls
   | Opt_KindSignatures
   | Opt_RoleAnnotations
   | Opt_ParallelListComp
   | Opt_TransformListComp
   | Opt_MonadComprehensions
   | Opt_GeneralizedNewtypeDeriving
   | Opt_RecursiveDo
   | Opt_PostfixOperators
   | Opt_TupleSections
   | Opt_PatternGuards
   | Opt_LiberalTypeSynonyms
   | Opt_RankNTypes
   | Opt_ImpredicativeTypes
   | Opt_TypeOperators
   | Opt_ExplicitNamespaces
   | Opt_PackageImports
   | Opt_ExplicitForAll
   | Opt_AlternativeLayoutRule
   | Opt_AlternativeLayoutRuleTransitional
   | Opt_DatatypeContexts
   | Opt_NondecreasingIndentation
   | Opt_RelaxedLayout
   | Opt_TraditionalRecordSyntax
   | Opt_LambdaCase
   | Opt_MultiWayIf
   | Opt_BinaryLiterals
   | Opt_NegativeLiterals
   | Opt_EmptyCase
   | Opt_PatternSynonyms
   | Opt_PartialTypeSignatures
   | Opt_NamedWildCards
   | Opt_StaticPointers
   deriving (Eq, Enum, Show)

type SigOf = Map ModuleName Module

getSigOf :: DynFlags -> ModuleName -> Maybe Module
getSigOf dflags n = Map.lookup n (sigOf dflags)

-- | Contains not only a collection of 'GeneralFlag's but also a plethora of
-- information relating to the compilation of a single file or GHC session
data DynFlags = DynFlags {
  ghcMode               :: GhcMode,
  ghcLink               :: GhcLink,
  hscTarget             :: HscTarget,
  settings              :: Settings,
  -- See Note [Signature parameters in TcGblEnv and DynFlags]
  sigOf                 :: SigOf,       -- ^ Compiling an hs-boot against impl.
  verbosity             :: Int,         -- ^ Verbosity level: see Note [Verbosity levels]
  optLevel              :: Int,         -- ^ Optimisation level
  simplPhases           :: Int,         -- ^ Number of simplifier phases
  maxSimplIterations    :: Int,         -- ^ Max simplifier iterations
  ruleCheck             :: Maybe String,
  strictnessBefore      :: [Int],       -- ^ Additional demand analysis

  parMakeCount          :: Maybe Int,   -- ^ The number of modules to compile in parallel
                                        --   in --make mode, where Nothing ==> compile as
                                        --   many in parallel as there are CPUs.

  enableTimeStats       :: Bool,        -- ^ Enable RTS timing statistics?
  ghcHeapSize           :: Maybe Int,   -- ^ The heap size to set.

  maxRelevantBinds      :: Maybe Int,   -- ^ Maximum number of bindings from the type envt
                                        --   to show in type error messages
  simplTickFactor       :: Int,         -- ^ Multiplier for simplifier ticks
  specConstrThreshold   :: Maybe Int,   -- ^ Threshold for SpecConstr
  specConstrCount       :: Maybe Int,   -- ^ Max number of specialisations for any one function
  specConstrRecursive   :: Int,         -- ^ Max number of specialisations for recursive types
                                        --   Not optional; otherwise ForceSpecConstr can diverge.
  liberateCaseThreshold :: Maybe Int,   -- ^ Threshold for LiberateCase
  floatLamArgs          :: Maybe Int,   -- ^ Arg count for lambda floating
                                        --   See CoreMonad.FloatOutSwitches

  historySize           :: Int,

  cmdlineHcIncludes     :: [String],    -- ^ @\-\#includes@
  importPaths           :: [FilePath],
  mainModIs             :: Module,
  mainFunIs             :: Maybe String,
  reductionDepth        :: IntWithInf,   -- ^ Typechecker maximum stack depth
  solverIterations      :: IntWithInf,   -- ^ Number of iterations in the constraints solver
                                         --   Typically only 1 is needed

  thisPackage           :: PackageKey,   -- ^ name of package currently being compiled

  -- ways
  ways                  :: [Way],       -- ^ Way flags from the command line
  buildTag              :: String,      -- ^ The global \"way\" (e.g. \"p\" for prof)
  rtsBuildTag           :: String,      -- ^ The RTS \"way\"

  -- For object splitting
  splitInfo             :: Maybe (String,Int),

  -- paths etc.
  objectDir             :: Maybe String,
  dylibInstallName      :: Maybe String,
  hiDir                 :: Maybe String,
  stubDir               :: Maybe String,
  dumpDir               :: Maybe String,

  objectSuf             :: String,
  hcSuf                 :: String,
  hiSuf                 :: String,

  canGenerateDynamicToo :: IORef Bool,
  dynObjectSuf          :: String,
  dynHiSuf              :: String,

  -- Packages.isDllName needs to know whether a call is within a
  -- single DLL or not. Normally it does this by seeing if the call
  -- is to the same package, but for the ghc package, we split the
  -- package between 2 DLLs. The dllSplit tells us which sets of
  -- modules are in which package.
  dllSplitFile          :: Maybe FilePath,
  dllSplit              :: Maybe [Set String],

  outputFile            :: Maybe String,
  dynOutputFile         :: Maybe String,
  outputHi              :: Maybe String,
  dynLibLoader          :: DynLibLoader,

  -- | This is set by 'DriverPipeline.runPipeline' based on where
  --    its output is going.
  dumpPrefix            :: Maybe FilePath,

  -- | Override the 'dumpPrefix' set by 'DriverPipeline.runPipeline'.
  --    Set by @-ddump-file-prefix@
  dumpPrefixForce       :: Maybe FilePath,

  ldInputs              :: [Option],

  includePaths          :: [String],
  libraryPaths          :: [String],
  frameworkPaths        :: [String],    -- used on darwin only
  cmdlineFrameworks     :: [String],    -- ditto

  rtsOpts               :: Maybe String,
  rtsOptsEnabled        :: RtsOptsEnabled,
  rtsOptsSuggestions    :: Bool,

  hpcDir                :: String,      -- ^ Path to store the .mix files

  -- Plugins
  pluginModNames        :: [ModuleName],
  pluginModNameOpts     :: [(ModuleName,String)],

  -- GHC API hooks
  hooks                 :: Hooks,

  --  For ghc -M
  depMakefile           :: FilePath,
  depIncludePkgDeps     :: Bool,
  depExcludeMods        :: [ModuleName],
  depSuffixes           :: [String],

  --  Package flags
  extraPkgConfs         :: [PkgConfRef] -> [PkgConfRef],
        -- ^ The @-package-db@ flags given on the command line, in the order
        -- they appeared.

  packageFlags          :: [PackageFlag],
        -- ^ The @-package@ and @-hide-package@ flags from the command-line
  packageEnv            :: Maybe FilePath,
        -- ^ Filepath to the package environment file (if overriding default)

  -- Package state
  -- NB. do not modify this field, it is calculated by
  -- Packages.initPackages
  pkgDatabase           :: Maybe [PackageConfig],
  pkgState              :: PackageState,

  -- Temporary files
  -- These have to be IORefs, because the defaultCleanupHandler needs to
  -- know what to clean when an exception happens
  filesToClean          :: IORef [FilePath],
  dirsToClean           :: IORef (Map FilePath FilePath),
  filesToNotIntermediateClean :: IORef [FilePath],
  -- The next available suffix to uniquely name a temp file, updated atomically
  nextTempSuffix        :: IORef Int,

  -- Names of files which were generated from -ddump-to-file; used to
  -- track which ones we need to truncate because it's our first run
  -- through
  generatedDumps        :: IORef (Set FilePath),

  -- hsc dynamic flags
  dumpFlags             :: IntSet,
  generalFlags          :: IntSet,
  warningFlags          :: IntSet,
  -- Don't change this without updating extensionFlags:
  language              :: Maybe Language,
  -- | Safe Haskell mode
  safeHaskell           :: SafeHaskellMode,
  safeInfer             :: Bool,
  safeInferred          :: Bool,
  -- We store the location of where some extension and flags were turned on so
  -- we can produce accurate error messages when Safe Haskell fails due to
  -- them.
  thOnLoc               :: SrcSpan,
  newDerivOnLoc         :: SrcSpan,
  overlapInstLoc        :: SrcSpan,
  incoherentOnLoc       :: SrcSpan,
  pkgTrustOnLoc         :: SrcSpan,
  warnSafeOnLoc         :: SrcSpan,
  warnUnsafeOnLoc       :: SrcSpan,
  trustworthyOnLoc      :: SrcSpan,
  -- Don't change this without updating extensionFlags:
  extensions            :: [OnOff ExtensionFlag],
  -- extensionFlags should always be equal to
  --     flattenExtensionFlags language extensions
  extensionFlags        :: IntSet,

  -- Unfolding control
  -- See Note [Discounts and thresholds] in CoreUnfold
  ufCreationThreshold   :: Int,
  ufUseThreshold        :: Int,
  ufFunAppDiscount      :: Int,
  ufDictDiscount        :: Int,
  ufKeenessFactor       :: Float,
  ufDearOp              :: Int,

  maxWorkerArgs         :: Int,

  ghciHistSize          :: Int,

  -- | MsgDoc output action: use "ErrUtils" instead of this if you can
  log_action            :: LogAction,
  flushOut              :: FlushOut,
  flushErr              :: FlushErr,

  haddockOptions        :: Maybe String,

  -- | GHCi scripts specified by -ghci-script, in reverse order
  ghciScripts           :: [String],

  -- Output style options
  pprUserLength         :: Int,
  pprCols               :: Int,
  traceLevel            :: Int, -- Standard level is 1. Less verbose is 0.

  useUnicode      :: Bool,

  -- | what kind of {-# SCC #-} to add automatically
  profAuto              :: ProfAuto,

  interactivePrint      :: Maybe String,

  llvmVersion           :: IORef Int,

  nextWrapperNum        :: IORef (ModuleEnv Int),

  -- | Machine dependant flags (-m<blah> stuff)
  sseVersion            :: Maybe SseVersion,
  avx                   :: Bool,
  avx2                  :: Bool,
  avx512cd              :: Bool, -- Enable AVX-512 Conflict Detection Instructions.
  avx512er              :: Bool, -- Enable AVX-512 Exponential and Reciprocal Instructions.
  avx512f               :: Bool, -- Enable AVX-512 instructions.
  avx512pf              :: Bool, -- Enable AVX-512 PreFetch Instructions.

  -- | Run-time linker information (what options we need, etc.)
  rtldInfo              :: IORef (Maybe LinkerInfo),

  -- | Run-time compiler information
  rtccInfo              :: IORef (Maybe CompilerInfo),

  -- Constants used to control the amount of optimization done.

  -- | Max size, in bytes, of inline array allocations.
  maxInlineAllocSize    :: Int,

  -- | Only inline memcpy if it generates no more than this many
  -- pseudo (roughly: Cmm) instructions.
  maxInlineMemcpyInsns  :: Int,

  -- | Only inline memset if it generates no more than this many
  -- pseudo (roughly: Cmm) instructions.
  maxInlineMemsetInsns  :: Int
}

class HasDynFlags m where
    getDynFlags :: m DynFlags

class ContainsDynFlags t where
    extractDynFlags :: t -> DynFlags
    replaceDynFlags :: t -> DynFlags -> t

data ProfAuto
  = NoProfAuto         -- ^ no SCC annotations added
  | ProfAutoAll        -- ^ top-level and nested functions are annotated
  | ProfAutoTop        -- ^ top-level functions annotated only
  | ProfAutoExports    -- ^ exported functions annotated only
  | ProfAutoCalls      -- ^ annotate call-sites
  deriving (Eq,Enum)

data Settings = Settings {
  sTargetPlatform        :: Platform,    -- Filled in by SysTools
  sGhcUsagePath          :: FilePath,    -- Filled in by SysTools
  sGhciUsagePath         :: FilePath,    -- ditto
  sTopDir                :: FilePath,
  sTmpDir                :: String,      -- no trailing '/'
  sProgramName           :: String,
  sProjectVersion        :: String,
  -- You shouldn't need to look things up in rawSettings directly.
  -- They should have their own fields instead.
  sRawSettings           :: [(String, String)],
  sExtraGccViaCFlags     :: [String],
  sSystemPackageConfig   :: FilePath,
  sLdSupportsCompactUnwind :: Bool,
  sLdSupportsBuildId       :: Bool,
  sLdSupportsFilelist      :: Bool,
  sLdIsGnuLd               :: Bool,
  -- commands for particular phases
  sPgm_L                 :: String,
  sPgm_P                 :: (String,[Option]),
  sPgm_F                 :: String,
  sPgm_c                 :: (String,[Option]),
  sPgm_s                 :: (String,[Option]),
  sPgm_a                 :: (String,[Option]),
  sPgm_l                 :: (String,[Option]),
  sPgm_dll               :: (String,[Option]),
  sPgm_T                 :: String,
  sPgm_sysman            :: String,
  sPgm_windres           :: String,
  sPgm_libtool           :: String,
  sPgm_lo                :: (String,[Option]), -- LLVM: opt llvm optimiser
  sPgm_lc                :: (String,[Option]), -- LLVM: llc static compiler
  -- options for particular phases
  sOpt_L                 :: [String],
  sOpt_P                 :: [String],
  sOpt_F                 :: [String],
  sOpt_c                 :: [String],
  sOpt_a                 :: [String],
  sOpt_l                 :: [String],
  sOpt_windres           :: [String],
  sOpt_lo                :: [String], -- LLVM: llvm optimiser
  sOpt_lc                :: [String], -- LLVM: llc static compiler

  sPlatformConstants     :: PlatformConstants
 }

targetPlatform :: DynFlags -> Platform
targetPlatform dflags = sTargetPlatform (settings dflags)
programName :: DynFlags -> String
programName dflags = sProgramName (settings dflags)
projectVersion :: DynFlags -> String
projectVersion dflags = sProjectVersion (settings dflags)
ghcUsagePath          :: DynFlags -> FilePath
ghcUsagePath dflags = sGhcUsagePath (settings dflags)
ghciUsagePath         :: DynFlags -> FilePath
ghciUsagePath dflags = sGhciUsagePath (settings dflags)
topDir                :: DynFlags -> FilePath
topDir dflags = sTopDir (settings dflags)
tmpDir                :: DynFlags -> String
tmpDir dflags = sTmpDir (settings dflags)
rawSettings           :: DynFlags -> [(String, String)]
rawSettings dflags = sRawSettings (settings dflags)
extraGccViaCFlags     :: DynFlags -> [String]
extraGccViaCFlags dflags = sExtraGccViaCFlags (settings dflags)
systemPackageConfig   :: DynFlags -> FilePath
systemPackageConfig dflags = sSystemPackageConfig (settings dflags)
pgm_L                 :: DynFlags -> String
pgm_L dflags = sPgm_L (settings dflags)
pgm_P                 :: DynFlags -> (String,[Option])
pgm_P dflags = sPgm_P (settings dflags)
pgm_F                 :: DynFlags -> String
pgm_F dflags = sPgm_F (settings dflags)
pgm_c                 :: DynFlags -> (String,[Option])
pgm_c dflags = sPgm_c (settings dflags)
pgm_s                 :: DynFlags -> (String,[Option])
pgm_s dflags = sPgm_s (settings dflags)
pgm_a                 :: DynFlags -> (String,[Option])
pgm_a dflags = sPgm_a (settings dflags)
pgm_l                 :: DynFlags -> (String,[Option])
pgm_l dflags = sPgm_l (settings dflags)
pgm_dll               :: DynFlags -> (String,[Option])
pgm_dll dflags = sPgm_dll (settings dflags)
pgm_T                 :: DynFlags -> String
pgm_T dflags = sPgm_T (settings dflags)
pgm_sysman            :: DynFlags -> String
pgm_sysman dflags = sPgm_sysman (settings dflags)
pgm_windres           :: DynFlags -> String
pgm_windres dflags = sPgm_windres (settings dflags)
pgm_libtool           :: DynFlags -> String
pgm_libtool dflags = sPgm_libtool (settings dflags)
pgm_lo                :: DynFlags -> (String,[Option])
pgm_lo dflags = sPgm_lo (settings dflags)
pgm_lc                :: DynFlags -> (String,[Option])
pgm_lc dflags = sPgm_lc (settings dflags)
opt_L                 :: DynFlags -> [String]
opt_L dflags = sOpt_L (settings dflags)
opt_P                 :: DynFlags -> [String]
opt_P dflags = concatMap (wayOptP (targetPlatform dflags)) (ways dflags)
            ++ sOpt_P (settings dflags)
opt_F                 :: DynFlags -> [String]
opt_F dflags = sOpt_F (settings dflags)
opt_c                 :: DynFlags -> [String]
opt_c dflags = concatMap (wayOptc (targetPlatform dflags)) (ways dflags)
            ++ sOpt_c (settings dflags)
opt_a                 :: DynFlags -> [String]
opt_a dflags = sOpt_a (settings dflags)
opt_l                 :: DynFlags -> [String]
opt_l dflags = concatMap (wayOptl (targetPlatform dflags)) (ways dflags)
            ++ sOpt_l (settings dflags)
opt_windres           :: DynFlags -> [String]
opt_windres dflags = sOpt_windres (settings dflags)
opt_lo                :: DynFlags -> [String]
opt_lo dflags = sOpt_lo (settings dflags)
opt_lc                :: DynFlags -> [String]
opt_lc dflags = sOpt_lc (settings dflags)

-- | The directory for this version of ghc in the user's app directory
-- (typically something like @~/.ghc/x86_64-linux-7.6.3@)
--
versionedAppDir :: DynFlags -> IO FilePath
versionedAppDir dflags = do
  appdir <- getAppUserDataDirectory (programName dflags)
  return $ appdir </> (TARGET_ARCH ++ '-':TARGET_OS ++ '-':projectVersion dflags)

-- | The target code type of the compilation (if any).
--
-- Whenever you change the target, also make sure to set 'ghcLink' to
-- something sensible.
--
-- 'HscNothing' can be used to avoid generating any output, however, note
-- that:
--
--  * If a program uses Template Haskell the typechecker may try to run code
--    from an imported module.  This will fail if no code has been generated
--    for this module.  You can use 'GHC.needsTemplateHaskell' to detect
--    whether this might be the case and choose to either switch to a
--    different target or avoid typechecking such modules.  (The latter may be
--    preferable for security reasons.)
--
data HscTarget
  = HscC           -- ^ Generate C code.
  | HscAsm         -- ^ Generate assembly using the native code generator.
  | HscLlvm        -- ^ Generate assembly using the llvm code generator.
  | HscInterpreted -- ^ Generate bytecode.  (Requires 'LinkInMemory')
  | HscNothing     -- ^ Don't generate any code.  See notes above.
  deriving (Eq, Show)

-- | Will this target result in an object file on the disk?
isObjectTarget :: HscTarget -> Bool
isObjectTarget HscC     = True
isObjectTarget HscAsm   = True
isObjectTarget HscLlvm  = True
isObjectTarget _        = False

-- | Does this target retain *all* top-level bindings for a module,
-- rather than just the exported bindings, in the TypeEnv and compiled
-- code (if any)?  In interpreted mode we do this, so that GHCi can
-- call functions inside a module.  In HscNothing mode we also do it,
-- so that Haddock can get access to the GlobalRdrEnv for a module
-- after typechecking it.
targetRetainsAllBindings :: HscTarget -> Bool
targetRetainsAllBindings HscInterpreted = True
targetRetainsAllBindings HscNothing     = True
targetRetainsAllBindings _              = False

-- | The 'GhcMode' tells us whether we're doing multi-module
-- compilation (controlled via the "GHC" API) or one-shot
-- (single-module) compilation.  This makes a difference primarily to
-- the "Finder": in one-shot mode we look for interface files for
-- imported modules, but in multi-module mode we look for source files
-- in order to check whether they need to be recompiled.
data GhcMode
  = CompManager         -- ^ @\-\-make@, GHCi, etc.
  | OneShot             -- ^ @ghc -c Foo.hs@
  | MkDepend            -- ^ @ghc -M@, see "Finder" for why we need this
  deriving Eq

instance Outputable GhcMode where
  ppr CompManager = ptext (sLit "CompManager")
  ppr OneShot     = ptext (sLit "OneShot")
  ppr MkDepend    = ptext (sLit "MkDepend")

isOneShot :: GhcMode -> Bool
isOneShot OneShot = True
isOneShot _other  = False

-- | What to do in the link step, if there is one.
data GhcLink
  = NoLink              -- ^ Don't link at all
  | LinkBinary          -- ^ Link object code into a binary
  | LinkInMemory        -- ^ Use the in-memory dynamic linker (works for both
                        --   bytecode and object code).
  | LinkDynLib          -- ^ Link objects into a dynamic lib (DLL on Windows, DSO on ELF platforms)
  | LinkStaticLib       -- ^ Link objects into a static lib
  deriving (Eq, Show)

isNoLink :: GhcLink -> Bool
isNoLink NoLink = True
isNoLink _      = False

-- | We accept flags which make packages visible, but how they select
-- the package varies; this data type reflects what selection criterion
-- is used.
data PackageArg =
      PackageArg String    -- ^ @-package@, by 'PackageName'
    | PackageIdArg String  -- ^ @-package-id@, by 'SourcePackageId'
    | PackageKeyArg String -- ^ @-package-key@, by 'InstalledPackageId'
  deriving (Eq, Show)

-- | Represents the renaming that may be associated with an exposed
-- package, e.g. the @rns@ part of @-package "foo (rns)"@.
--
-- Here are some example parsings of the package flags (where
-- a string literal is punned to be a 'ModuleName':
--
--      * @-package foo@ is @ModRenaming True []@
--      * @-package foo ()@ is @ModRenaming False []@
--      * @-package foo (A)@ is @ModRenaming False [("A", "A")]@
--      * @-package foo (A as B)@ is @ModRenaming False [("A", "B")]@
--      * @-package foo with (A as B)@ is @ModRenaming True [("A", "B")]@
data ModRenaming = ModRenaming {
    modRenamingWithImplicit :: Bool, -- ^ Bring all exposed modules into scope?
    modRenamings :: [(ModuleName, ModuleName)] -- ^ Bring module @m@ into scope
                                               --   under name @n@.
  } deriving (Eq)

-- | Flags for manipulating packages.
data PackageFlag
  = ExposePackage   PackageArg ModRenaming -- ^ @-package@, @-package-id@
                                           -- and @-package-key@
  | HidePackage     String -- ^ @-hide-package@
  | IgnorePackage   String -- ^ @-ignore-package@
  | TrustPackage    String -- ^ @-trust-package@
  | DistrustPackage String -- ^ @-distrust-package@
  deriving (Eq)

defaultHscTarget :: Platform -> HscTarget
defaultHscTarget = defaultObjectTarget

-- | The 'HscTarget' value corresponding to the default way to create
-- object files on the current platform.
defaultObjectTarget :: Platform -> HscTarget
defaultObjectTarget platform
  | platformUnregisterised platform     =  HscC
  | cGhcWithNativeCodeGen == "YES"      =  HscAsm
  | otherwise                           =  HscLlvm

tablesNextToCode :: DynFlags -> Bool
tablesNextToCode dflags
    = mkTablesNextToCode (platformUnregisterised (targetPlatform dflags))

-- Determines whether we will be compiling
-- info tables that reside just before the entry code, or with an
-- indirection to the entry code.  See TABLES_NEXT_TO_CODE in
-- includes/rts/storage/InfoTables.h.
mkTablesNextToCode :: Bool -> Bool
mkTablesNextToCode unregisterised
    = not unregisterised && cGhcEnableTablesNextToCode == "YES"

data DynLibLoader
  = Deployable
  | SystemDependent
  deriving Eq

data RtsOptsEnabled = RtsOptsNone | RtsOptsSafeOnly | RtsOptsAll
  deriving (Show)

-----------------------------------------------------------------------------
-- Ways

-- The central concept of a "way" is that all objects in a given
-- program must be compiled in the same "way".  Certain options change
-- parameters of the virtual machine, eg. profiling adds an extra word
-- to the object header, so profiling objects cannot be linked with
-- non-profiling objects.

-- After parsing the command-line options, we determine which "way" we
-- are building - this might be a combination way, eg. profiling+threaded.

-- We then find the "build-tag" associated with this way, and this
-- becomes the suffix used to find .hi files and libraries used in
-- this compilation.

data Way
  = WayCustom String -- for GHC API clients building custom variants
  | WayThreaded
  | WayDebug
  | WayProf
  | WayEventLog
  | WayPar
  | WayDyn
  deriving (Eq, Ord, Show)

allowed_combination :: [Way] -> Bool
allowed_combination way = and [ x `allowedWith` y
                              | x <- way, y <- way, x < y ]
  where
        -- Note ordering in these tests: the left argument is
        -- <= the right argument, according to the Ord instance
        -- on Way above.

        -- dyn is allowed with everything
        _ `allowedWith` WayDyn                  = True
        WayDyn `allowedWith` _                  = True

        -- debug is allowed with everything
        _ `allowedWith` WayDebug                = True
        WayDebug `allowedWith` _                = True

        (WayCustom {}) `allowedWith` _          = True
        WayThreaded `allowedWith` WayProf       = True
        WayThreaded `allowedWith` WayEventLog   = True
        _ `allowedWith` _                       = False

mkBuildTag :: [Way] -> String
mkBuildTag ways = concat (intersperse "_" (map wayTag ways))

wayTag :: Way -> String
wayTag (WayCustom xs) = xs
wayTag WayThreaded = "thr"
wayTag WayDebug    = "debug"
wayTag WayDyn      = "dyn"
wayTag WayProf     = "p"
wayTag WayEventLog = "l"
wayTag WayPar      = "mp"

wayRTSOnly :: Way -> Bool
wayRTSOnly (WayCustom {}) = False
wayRTSOnly WayThreaded = True
wayRTSOnly WayDebug    = True
wayRTSOnly WayDyn      = False
wayRTSOnly WayProf     = False
wayRTSOnly WayEventLog = True
wayRTSOnly WayPar      = False

wayDesc :: Way -> String
wayDesc (WayCustom xs) = xs
wayDesc WayThreaded = "Threaded"
wayDesc WayDebug    = "Debug"
wayDesc WayDyn      = "Dynamic"
wayDesc WayProf     = "Profiling"
wayDesc WayEventLog = "RTS Event Logging"
wayDesc WayPar      = "Parallel"

-- Turn these flags on when enabling this way
wayGeneralFlags :: Platform -> Way -> [GeneralFlag]
wayGeneralFlags _ (WayCustom {}) = []
wayGeneralFlags _ WayThreaded = []
wayGeneralFlags _ WayDebug    = []
wayGeneralFlags _ WayDyn      = [Opt_PIC]
    -- We could get away without adding -fPIC when compiling the
    -- modules of a program that is to be linked with -dynamic; the
    -- program itself does not need to be position-independent, only
    -- the libraries need to be.  HOWEVER, GHCi links objects into a
    -- .so before loading the .so using the system linker.  Since only
    -- PIC objects can be linked into a .so, we have to compile even
    -- modules of the main program with -fPIC when using -dynamic.
wayGeneralFlags _ WayProf     = [Opt_SccProfilingOn]
wayGeneralFlags _ WayEventLog = []
wayGeneralFlags _ WayPar      = [Opt_Parallel]

-- Turn these flags off when enabling this way
wayUnsetGeneralFlags :: Platform -> Way -> [GeneralFlag]
wayUnsetGeneralFlags _ (WayCustom {}) = []
wayUnsetGeneralFlags _ WayThreaded = []
wayUnsetGeneralFlags _ WayDebug    = []
wayUnsetGeneralFlags _ WayDyn      = [-- There's no point splitting objects
                                      -- when we're going to be dynamically
                                      -- linking. Plus it breaks compilation
                                      -- on OSX x86.
                                      Opt_SplitObjs]
wayUnsetGeneralFlags _ WayProf     = []
wayUnsetGeneralFlags _ WayEventLog = []
wayUnsetGeneralFlags _ WayPar      = []

wayExtras :: Platform -> Way -> DynFlags -> DynFlags
wayExtras _ (WayCustom {}) dflags = dflags
wayExtras _ WayThreaded dflags = dflags
wayExtras _ WayDebug    dflags = dflags
wayExtras _ WayDyn      dflags = dflags
wayExtras _ WayProf     dflags = dflags
wayExtras _ WayEventLog dflags = dflags
wayExtras _ WayPar      dflags = exposePackage' "concurrent" dflags

wayOptc :: Platform -> Way -> [String]
wayOptc _ (WayCustom {}) = []
wayOptc platform WayThreaded = case platformOS platform of
                               OSOpenBSD -> ["-pthread"]
                               OSNetBSD  -> ["-pthread"]
                               _         -> []
wayOptc _ WayDebug      = []
wayOptc _ WayDyn        = []
wayOptc _ WayProf       = ["-DPROFILING"]
wayOptc _ WayEventLog   = ["-DTRACING"]
wayOptc _ WayPar        = ["-DPAR", "-w"]

wayOptl :: Platform -> Way -> [String]
wayOptl _ (WayCustom {}) = []
wayOptl platform WayThreaded =
        case platformOS platform of
        -- FreeBSD's default threading library is the KSE-based M:N libpthread,
        -- which GHC has some problems with.  It's currently not clear whether
        -- the problems are our fault or theirs, but it seems that using the
        -- alternative 1:1 threading library libthr works around it:
        OSFreeBSD  -> ["-lthr"]
        OSOpenBSD  -> ["-pthread"]
        OSNetBSD   -> ["-pthread"]
        _          -> []
wayOptl _ WayDebug      = []
wayOptl _ WayDyn        = []
wayOptl _ WayProf       = []
wayOptl _ WayEventLog   = []
wayOptl _ WayPar        = ["-L${PVM_ROOT}/lib/${PVM_ARCH}",
                           "-lpvm3",
                           "-lgpvm3"]

wayOptP :: Platform -> Way -> [String]
wayOptP _ (WayCustom {}) = []
wayOptP _ WayThreaded = []
wayOptP _ WayDebug    = []
wayOptP _ WayDyn      = []
wayOptP _ WayProf     = ["-DPROFILING"]
wayOptP _ WayEventLog = ["-DTRACING"]
wayOptP _ WayPar      = ["-D__PARALLEL_HASKELL__"]

whenGeneratingDynamicToo :: MonadIO m => DynFlags -> m () -> m ()
whenGeneratingDynamicToo dflags f = ifGeneratingDynamicToo dflags f (return ())

ifGeneratingDynamicToo :: MonadIO m => DynFlags -> m a -> m a -> m a
ifGeneratingDynamicToo dflags f g = generateDynamicTooConditional dflags f g g

whenCannotGenerateDynamicToo :: MonadIO m => DynFlags -> m () -> m ()
whenCannotGenerateDynamicToo dflags f
    = ifCannotGenerateDynamicToo dflags f (return ())

ifCannotGenerateDynamicToo :: MonadIO m => DynFlags -> m a -> m a -> m a
ifCannotGenerateDynamicToo dflags f g
    = generateDynamicTooConditional dflags g f g

generateDynamicTooConditional :: MonadIO m
                              => DynFlags -> m a -> m a -> m a -> m a
generateDynamicTooConditional dflags canGen cannotGen notTryingToGen
    = if gopt Opt_BuildDynamicToo dflags
      then do let ref = canGenerateDynamicToo dflags
              b <- liftIO $ readIORef ref
              if b then canGen else cannotGen
      else notTryingToGen

dynamicTooMkDynamicDynFlags :: DynFlags -> DynFlags
dynamicTooMkDynamicDynFlags dflags0
    = let dflags1 = addWay' WayDyn dflags0
          dflags2 = dflags1 {
                        outputFile = dynOutputFile dflags1,
                        hiSuf = dynHiSuf dflags1,
                        objectSuf = dynObjectSuf dflags1
                    }
          dflags3 = updateWays dflags2
          dflags4 = gopt_unset dflags3 Opt_BuildDynamicToo
      in dflags4

-----------------------------------------------------------------------------

-- | Used by 'GHC.runGhc' to partially initialize a new 'DynFlags' value
initDynFlags :: DynFlags -> IO DynFlags
initDynFlags dflags = do
 let -- We can't build with dynamic-too on Windows, as labels before
     -- the fork point are different depending on whether we are
     -- building dynamically or not.
     platformCanGenerateDynamicToo
         = platformOS (targetPlatform dflags) /= OSMinGW32
 refCanGenerateDynamicToo <- newIORef platformCanGenerateDynamicToo
 refNextTempSuffix <- newIORef 0
 refFilesToClean <- newIORef []
 refDirsToClean <- newIORef Map.empty
 refFilesToNotIntermediateClean <- newIORef []
 refGeneratedDumps <- newIORef Set.empty
 refLlvmVersion <- newIORef 28
 refRtldInfo <- newIORef Nothing
 refRtccInfo <- newIORef Nothing
 wrapperNum <- newIORef emptyModuleEnv
 canUseUnicode <- do let enc = localeEncoding
                         str = "‘’"
                     (withCString enc str $ \cstr ->
                          do str' <- peekCString enc cstr
                             return (str == str'))
                         `catchIOError` \_ -> return False
 return dflags{
        canGenerateDynamicToo = refCanGenerateDynamicToo,
        nextTempSuffix = refNextTempSuffix,
        filesToClean   = refFilesToClean,
        dirsToClean    = refDirsToClean,
        filesToNotIntermediateClean = refFilesToNotIntermediateClean,
        generatedDumps = refGeneratedDumps,
        llvmVersion    = refLlvmVersion,
        nextWrapperNum = wrapperNum,
        useUnicode    = canUseUnicode,
        rtldInfo      = refRtldInfo,
        rtccInfo      = refRtccInfo
        }

-- | The normal 'DynFlags'. Note that they are not suitable for use in this form
-- and must be fully initialized by 'GHC.runGhc' first.
defaultDynFlags :: Settings -> DynFlags
defaultDynFlags mySettings =
-- See Note [Updating flag description in the User's Guide]
     DynFlags {
        ghcMode                 = CompManager,
        ghcLink                 = LinkBinary,
        hscTarget               = defaultHscTarget (sTargetPlatform mySettings),
        sigOf                   = Map.empty,
        verbosity               = 0,
        optLevel                = 0,
        simplPhases             = 2,
        maxSimplIterations      = 4,
        ruleCheck               = Nothing,
        maxRelevantBinds        = Just 6,
        simplTickFactor         = 100,
        specConstrThreshold     = Just 2000,
        specConstrCount         = Just 3,
        specConstrRecursive     = 3,
        liberateCaseThreshold   = Just 2000,
        floatLamArgs            = Just 0, -- Default: float only if no fvs

        historySize             = 20,
        strictnessBefore        = [],

        parMakeCount            = Just 1,

        enableTimeStats         = False,
        ghcHeapSize             = Nothing,

        cmdlineHcIncludes       = [],
        importPaths             = ["."],
        mainModIs               = mAIN,
        mainFunIs               = Nothing,
        reductionDepth          = treatZeroAsInf mAX_REDUCTION_DEPTH,
        solverIterations        = treatZeroAsInf mAX_SOLVER_ITERATIONS,

        thisPackage             = mainPackageKey,

        objectDir               = Nothing,
        dylibInstallName        = Nothing,
        hiDir                   = Nothing,
        stubDir                 = Nothing,
        dumpDir                 = Nothing,

        objectSuf               = phaseInputExt StopLn,
        hcSuf                   = phaseInputExt HCc,
        hiSuf                   = "hi",

        canGenerateDynamicToo   = panic "defaultDynFlags: No canGenerateDynamicToo",
        dynObjectSuf            = "dyn_" ++ phaseInputExt StopLn,
        dynHiSuf                = "dyn_hi",

        dllSplitFile            = Nothing,
        dllSplit                = Nothing,

        pluginModNames          = [],
        pluginModNameOpts       = [],
        hooks                   = emptyHooks,

        outputFile              = Nothing,
        dynOutputFile           = Nothing,
        outputHi                = Nothing,
        dynLibLoader            = SystemDependent,
        dumpPrefix              = Nothing,
        dumpPrefixForce         = Nothing,
        ldInputs                = [],
        includePaths            = [],
        libraryPaths            = [],
        frameworkPaths          = [],
        cmdlineFrameworks       = [],
        rtsOpts                 = Nothing,
        rtsOptsEnabled          = RtsOptsSafeOnly,
        rtsOptsSuggestions      = True,

        hpcDir                  = ".hpc",

        extraPkgConfs           = id,
        packageFlags            = [],
        packageEnv              = Nothing,
        pkgDatabase             = Nothing,
        -- This gets filled in with GHC.setSessionDynFlags
        pkgState                = emptyPackageState,
        ways                    = defaultWays mySettings,
        buildTag                = mkBuildTag (defaultWays mySettings),
        rtsBuildTag             = mkBuildTag (defaultWays mySettings),
        splitInfo               = Nothing,
        settings                = mySettings,
        -- ghc -M values
        depMakefile       = "Makefile",
        depIncludePkgDeps = False,
        depExcludeMods    = [],
        depSuffixes       = [],
        -- end of ghc -M values
        nextTempSuffix = panic "defaultDynFlags: No nextTempSuffix",
        filesToClean   = panic "defaultDynFlags: No filesToClean",
        dirsToClean    = panic "defaultDynFlags: No dirsToClean",
        filesToNotIntermediateClean = panic "defaultDynFlags: No filesToNotIntermediateClean",
        generatedDumps = panic "defaultDynFlags: No generatedDumps",
        haddockOptions = Nothing,
        dumpFlags = IntSet.empty,
        generalFlags = IntSet.fromList (map fromEnum (defaultFlags mySettings)),
        warningFlags = IntSet.fromList (map fromEnum standardWarnings),
        ghciScripts = [],
        language = Nothing,
        safeHaskell = Sf_None,
        safeInfer   = True,
        safeInferred = True,
        thOnLoc = noSrcSpan,
        newDerivOnLoc = noSrcSpan,
        overlapInstLoc = noSrcSpan,
        incoherentOnLoc = noSrcSpan,
        pkgTrustOnLoc = noSrcSpan,
        warnSafeOnLoc = noSrcSpan,
        warnUnsafeOnLoc = noSrcSpan,
        trustworthyOnLoc = noSrcSpan,
        extensions = [],
        extensionFlags = flattenExtensionFlags Nothing [],

        -- The ufCreationThreshold threshold must be reasonably high to
        -- take account of possible discounts.
        -- E.g. 450 is not enough in 'fulsom' for Interval.sqr to inline
        -- into Csg.calc (The unfolding for sqr never makes it into the
        -- interface file.)
        ufCreationThreshold = 750,
        ufUseThreshold      = 60,
        ufFunAppDiscount    = 60,
        -- Be fairly keen to inline a fuction if that means
        -- we'll be able to pick the right method from a dictionary
        ufDictDiscount      = 30,
        ufKeenessFactor     = 1.5,
        ufDearOp            = 40,

        maxWorkerArgs = 10,

        ghciHistSize = 50, -- keep a log of length 50 by default

        log_action = defaultLogAction,
        flushOut = defaultFlushOut,
        flushErr = defaultFlushErr,
        pprUserLength = 5,
        pprCols = 100,
        useUnicode = False,
        traceLevel = 1,
        profAuto = NoProfAuto,
        llvmVersion = panic "defaultDynFlags: No llvmVersion",
        interactivePrint = Nothing,
        nextWrapperNum = panic "defaultDynFlags: No nextWrapperNum",
        sseVersion = Nothing,
        avx = False,
        avx2 = False,
        avx512cd = False,
        avx512er = False,
        avx512f = False,
        avx512pf = False,
        rtldInfo = panic "defaultDynFlags: no rtldInfo",
        rtccInfo = panic "defaultDynFlags: no rtccInfo",

        maxInlineAllocSize = 128,
        maxInlineMemcpyInsns = 32,
        maxInlineMemsetInsns = 32
      }

defaultWays :: Settings -> [Way]
defaultWays settings = if pc_DYNAMIC_BY_DEFAULT (sPlatformConstants settings)
                       then [WayDyn]
                       else []

interpWays :: [Way]
interpWays = if dynamicGhc
             then [WayDyn]
             else []

--------------------------------------------------------------------------

type FatalMessager = String -> IO ()
type LogAction = DynFlags -> Severity -> SrcSpan -> PprStyle -> MsgDoc -> IO ()

defaultFatalMessager :: FatalMessager
defaultFatalMessager = hPutStrLn stderr

defaultLogAction :: LogAction
defaultLogAction dflags severity srcSpan style msg
    = case severity of
      SevOutput      -> printSDoc msg style
      SevDump        -> printSDoc (msg $$ blankLine) style
      SevInteractive -> putStrSDoc msg style
      SevInfo        -> printErrs msg style
      SevFatal       -> printErrs msg style
      _              -> do hPutChar stderr '\n'
                           printErrs (mkLocMessage severity srcSpan msg) style
                           -- careful (#2302): printErrs prints in UTF-8,
                           -- whereas converting to string first and using
                           -- hPutStr would just emit the low 8 bits of
                           -- each unicode char.
    where printSDoc  = defaultLogActionHPrintDoc  dflags stdout
          printErrs  = defaultLogActionHPrintDoc  dflags stderr
          putStrSDoc = defaultLogActionHPutStrDoc dflags stdout

defaultLogActionHPrintDoc :: DynFlags -> Handle -> SDoc -> PprStyle -> IO ()
defaultLogActionHPrintDoc dflags h d sty
 = defaultLogActionHPutStrDoc dflags h (d $$ text "") sty
      -- Adds a newline

defaultLogActionHPutStrDoc :: DynFlags -> Handle -> SDoc -> PprStyle -> IO ()
defaultLogActionHPutStrDoc dflags h d sty
  = Pretty.printDoc_ Pretty.PageMode (pprCols dflags) h doc
  where   -- Don't add a newline at the end, so that successive
          -- calls to this log-action can output all on the same line
    doc = runSDoc d (initSDocContext dflags sty)

newtype FlushOut = FlushOut (IO ())

defaultFlushOut :: FlushOut
defaultFlushOut = FlushOut $ hFlush stdout

newtype FlushErr = FlushErr (IO ())

defaultFlushErr :: FlushErr
defaultFlushErr = FlushErr $ hFlush stderr

{-
Note [Verbosity levels]
~~~~~~~~~~~~~~~~~~~~~~~
    0   |   print errors & warnings only
    1   |   minimal verbosity: print "compiling M ... done." for each module.
    2   |   equivalent to -dshow-passes
    3   |   equivalent to existing "ghc -v"
    4   |   "ghc -v -ddump-most"
    5   |   "ghc -v -ddump-all"
-}

data OnOff a = On a
             | Off a

-- OnOffs accumulate in reverse order, so we use foldr in order to
-- process them in the right order
flattenExtensionFlags :: Maybe Language -> [OnOff ExtensionFlag] -> IntSet
flattenExtensionFlags ml = foldr f defaultExtensionFlags
    where f (On f)  flags = IntSet.insert (fromEnum f) flags
          f (Off f) flags = IntSet.delete (fromEnum f) flags
          defaultExtensionFlags = IntSet.fromList (map fromEnum (languageExtensions ml))

languageExtensions :: Maybe Language -> [ExtensionFlag]

languageExtensions Nothing
    -- Nothing => the default case
    = Opt_NondecreasingIndentation -- This has been on by default for some time
    : delete Opt_DatatypeContexts  -- The Haskell' committee decided to
                                   -- remove datatype contexts from the
                                   -- language:
   -- http://www.haskell.org/pipermail/haskell-prime/2011-January/003335.html
      (languageExtensions (Just Haskell2010))

   -- NB: MonoPatBinds is no longer the default

languageExtensions (Just Haskell98)
    = [Opt_ImplicitPrelude,
       Opt_MonomorphismRestriction,
       Opt_NPlusKPatterns,
       Opt_DatatypeContexts,
       Opt_TraditionalRecordSyntax,
       Opt_NondecreasingIndentation
           -- strictly speaking non-standard, but we always had this
           -- on implicitly before the option was added in 7.1, and
           -- turning it off breaks code, so we're keeping it on for
           -- backwards compatibility.  Cabal uses -XHaskell98 by
           -- default unless you specify another language.
      ]

languageExtensions (Just Haskell2010)
    = [Opt_ImplicitPrelude,
       Opt_MonomorphismRestriction,
       Opt_DatatypeContexts,
       Opt_TraditionalRecordSyntax,
       Opt_EmptyDataDecls,
       Opt_ForeignFunctionInterface,
       Opt_PatternGuards,
       Opt_DoAndIfThenElse,
       Opt_RelaxedPolyRec]

-- | Test whether a 'DumpFlag' is set
dopt :: DumpFlag -> DynFlags -> Bool
dopt f dflags = (fromEnum f `IntSet.member` dumpFlags dflags)
             || (verbosity dflags >= 4 && enableIfVerbose f)
    where enableIfVerbose Opt_D_dump_tc_trace               = False
          enableIfVerbose Opt_D_dump_rn_trace               = False
          enableIfVerbose Opt_D_dump_cs_trace               = False
          enableIfVerbose Opt_D_dump_if_trace               = False
          enableIfVerbose Opt_D_dump_vt_trace               = False
          enableIfVerbose Opt_D_dump_tc                     = False
          enableIfVerbose Opt_D_dump_rn                     = False
          enableIfVerbose Opt_D_dump_rn_stats               = False
          enableIfVerbose Opt_D_dump_hi_diffs               = False
          enableIfVerbose Opt_D_verbose_core2core           = False
          enableIfVerbose Opt_D_verbose_stg2stg             = False
          enableIfVerbose Opt_D_dump_splices                = False
          enableIfVerbose Opt_D_th_dec_file                 = False
          enableIfVerbose Opt_D_dump_rule_firings           = False
          enableIfVerbose Opt_D_dump_rule_rewrites          = False
          enableIfVerbose Opt_D_dump_simpl_trace            = False
          enableIfVerbose Opt_D_dump_rtti                   = False
          enableIfVerbose Opt_D_dump_inlinings              = False
          enableIfVerbose Opt_D_dump_core_stats             = False
          enableIfVerbose Opt_D_dump_asm_stats              = False
          enableIfVerbose Opt_D_dump_types                  = False
          enableIfVerbose Opt_D_dump_simpl_iterations       = False
          enableIfVerbose Opt_D_dump_ticked                 = False
          enableIfVerbose Opt_D_dump_view_pattern_commoning = False
          enableIfVerbose Opt_D_dump_mod_cycles             = False
          enableIfVerbose Opt_D_dump_mod_map                = False
          enableIfVerbose _                                 = True

-- | Set a 'DumpFlag'
dopt_set :: DynFlags -> DumpFlag -> DynFlags
dopt_set dfs f = dfs{ dumpFlags = IntSet.insert (fromEnum f) (dumpFlags dfs) }

-- | Unset a 'DumpFlag'
dopt_unset :: DynFlags -> DumpFlag -> DynFlags
dopt_unset dfs f = dfs{ dumpFlags = IntSet.delete (fromEnum f) (dumpFlags dfs) }

-- | Test whether a 'GeneralFlag' is set
gopt :: GeneralFlag -> DynFlags -> Bool
gopt f dflags  = fromEnum f `IntSet.member` generalFlags dflags

-- | Set a 'GeneralFlag'
gopt_set :: DynFlags -> GeneralFlag -> DynFlags
gopt_set dfs f = dfs{ generalFlags = IntSet.insert (fromEnum f) (generalFlags dfs) }

-- | Unset a 'GeneralFlag'
gopt_unset :: DynFlags -> GeneralFlag -> DynFlags
gopt_unset dfs f = dfs{ generalFlags = IntSet.delete (fromEnum f) (generalFlags dfs) }

-- | Test whether a 'WarningFlag' is set
wopt :: WarningFlag -> DynFlags -> Bool
wopt f dflags  = fromEnum f `IntSet.member` warningFlags dflags

-- | Set a 'WarningFlag'
wopt_set :: DynFlags -> WarningFlag -> DynFlags
wopt_set dfs f = dfs{ warningFlags = IntSet.insert (fromEnum f) (warningFlags dfs) }

-- | Unset a 'WarningFlag'
wopt_unset :: DynFlags -> WarningFlag -> DynFlags
wopt_unset dfs f = dfs{ warningFlags = IntSet.delete (fromEnum f) (warningFlags dfs) }

-- | Test whether a 'ExtensionFlag' is set
xopt :: ExtensionFlag -> DynFlags -> Bool
xopt f dflags = fromEnum f `IntSet.member` extensionFlags dflags

-- | Set a 'ExtensionFlag'
xopt_set :: DynFlags -> ExtensionFlag -> DynFlags
xopt_set dfs f
    = let onoffs = On f : extensions dfs
      in dfs { extensions = onoffs,
               extensionFlags = flattenExtensionFlags (language dfs) onoffs }

-- | Unset a 'ExtensionFlag'
xopt_unset :: DynFlags -> ExtensionFlag -> DynFlags
xopt_unset dfs f
    = let onoffs = Off f : extensions dfs
      in dfs { extensions = onoffs,
               extensionFlags = flattenExtensionFlags (language dfs) onoffs }

lang_set :: DynFlags -> Maybe Language -> DynFlags
lang_set dflags lang =
   dflags {
            language = lang,
            extensionFlags = flattenExtensionFlags lang (extensions dflags)
          }

-- | Check whether to use unicode syntax for output
useUnicodeSyntax :: DynFlags -> Bool
useUnicodeSyntax = gopt Opt_PrintUnicodeSyntax

-- | Set the Haskell language standard to use
setLanguage :: Language -> DynP ()
setLanguage l = upd (`lang_set` Just l)

-- | Some modules have dependencies on others through the DynFlags rather than textual imports
dynFlagDependencies :: DynFlags -> [ModuleName]
dynFlagDependencies = pluginModNames

-- | Is the -fpackage-trust mode on
packageTrustOn :: DynFlags -> Bool
packageTrustOn = gopt Opt_PackageTrust

-- | Is Safe Haskell on in some way (including inference mode)
safeHaskellOn :: DynFlags -> Bool
safeHaskellOn dflags = safeHaskell dflags /= Sf_None || safeInferOn dflags

-- | Is the Safe Haskell safe language in use
safeLanguageOn :: DynFlags -> Bool
safeLanguageOn dflags = safeHaskell dflags == Sf_Safe

-- | Is the Safe Haskell safe inference mode active
safeInferOn :: DynFlags -> Bool
safeInferOn = safeInfer

-- | Test if Safe Imports are on in some form
safeImportsOn :: DynFlags -> Bool
safeImportsOn dflags = safeHaskell dflags == Sf_Unsafe ||
                       safeHaskell dflags == Sf_Trustworthy ||
                       safeHaskell dflags == Sf_Safe

-- | Set a 'Safe Haskell' flag
setSafeHaskell :: SafeHaskellMode -> DynP ()
setSafeHaskell s = updM f
    where f dfs = do
              let sf = safeHaskell dfs
              safeM <- combineSafeFlags sf s
              case s of
                Sf_Safe -> return $ dfs { safeHaskell = safeM, safeInfer = False }
                -- leave safe inferrence on in Trustworthy mode so we can warn
                -- if it could have been inferred safe.
                Sf_Trustworthy -> do
                  l <- getCurLoc
                  return $ dfs { safeHaskell = safeM, trustworthyOnLoc = l }
                -- leave safe inference on in Unsafe mode as well.
                _ -> return $ dfs { safeHaskell = safeM }

-- | Are all direct imports required to be safe for this Safe Haskell mode?
-- Direct imports are when the code explicitly imports a module
safeDirectImpsReq :: DynFlags -> Bool
safeDirectImpsReq d = safeLanguageOn d

-- | Are all implicit imports required to be safe for this Safe Haskell mode?
-- Implicit imports are things in the prelude. e.g System.IO when print is used.
safeImplicitImpsReq :: DynFlags -> Bool
safeImplicitImpsReq d = safeLanguageOn d

-- | Combine two Safe Haskell modes correctly. Used for dealing with multiple flags.
-- This makes Safe Haskell very much a monoid but for now I prefer this as I don't
-- want to export this functionality from the module but do want to export the
-- type constructors.
combineSafeFlags :: SafeHaskellMode -> SafeHaskellMode -> DynP SafeHaskellMode
combineSafeFlags a b | a == Sf_None         = return b
                     | b == Sf_None         = return a
                     | a == b               = return a
                     | otherwise            = addErr errm >> return (panic errm)
    where errm = "Incompatible Safe Haskell flags! ("
                    ++ show a ++ ", " ++ show b ++ ")"

-- | A list of unsafe flags under Safe Haskell. Tuple elements are:
--     * name of the flag
--     * function to get srcspan that enabled the flag
--     * function to test if the flag is on
--     * function to turn the flag off
unsafeFlags, unsafeFlagsForInfer
  :: [(String, DynFlags -> SrcSpan, DynFlags -> Bool, DynFlags -> DynFlags)]
unsafeFlags = [ ("-XGeneralizedNewtypeDeriving", newDerivOnLoc,
                    xopt Opt_GeneralizedNewtypeDeriving,
                    flip xopt_unset Opt_GeneralizedNewtypeDeriving)
              , ("-XTemplateHaskell", thOnLoc,
                    xopt Opt_TemplateHaskell,
                    flip xopt_unset Opt_TemplateHaskell)
              ]
unsafeFlagsForInfer = unsafeFlags


-- | Retrieve the options corresponding to a particular @opt_*@ field in the correct order
getOpts :: DynFlags             -- ^ 'DynFlags' to retrieve the options from
        -> (DynFlags -> [a])    -- ^ Relevant record accessor: one of the @opt_*@ accessors
        -> [a]                  -- ^ Correctly ordered extracted options
getOpts dflags opts = reverse (opts dflags)
        -- We add to the options from the front, so we need to reverse the list

-- | Gets the verbosity flag for the current verbosity level. This is fed to
-- other tools, so GHC-specific verbosity flags like @-ddump-most@ are not included
getVerbFlags :: DynFlags -> [String]
getVerbFlags dflags
  | verbosity dflags >= 4 = ["-v"]
  | otherwise             = []

setObjectDir, setHiDir, setStubDir, setDumpDir, setOutputDir,
         setDynObjectSuf, setDynHiSuf,
         setDylibInstallName,
         setObjectSuf, setHiSuf, setHcSuf, parseDynLibLoaderMode,
         setPgmP, addOptl, addOptc, addOptP,
         addCmdlineFramework, addHaddockOpts, addGhciScript,
         setInteractivePrint
   :: String -> DynFlags -> DynFlags
setOutputFile, setDynOutputFile, setOutputHi, setDumpPrefixForce
   :: Maybe String -> DynFlags -> DynFlags

setObjectDir  f d = d{ objectDir  = Just f}
setHiDir      f d = d{ hiDir      = Just f}
setStubDir    f d = d{ stubDir    = Just f, includePaths = f : includePaths d }
  -- -stubdir D adds an implicit -I D, so that gcc can find the _stub.h file
  -- \#included from the .hc file when compiling via C (i.e. unregisterised
  -- builds).
setDumpDir    f d = d{ dumpDir    = Just f}
setOutputDir  f = setObjectDir f . setHiDir f . setStubDir f . setDumpDir f
setDylibInstallName  f d = d{ dylibInstallName = Just f}

setObjectSuf    f d = d{ objectSuf    = f}
setDynObjectSuf f d = d{ dynObjectSuf = f}
setHiSuf        f d = d{ hiSuf        = f}
setDynHiSuf     f d = d{ dynHiSuf     = f}
setHcSuf        f d = d{ hcSuf        = f}

setOutputFile f d = d{ outputFile = f}
setDynOutputFile f d = d{ dynOutputFile = f}
setOutputHi   f d = d{ outputHi   = f}

parseSigOf :: String -> SigOf
parseSigOf str = case filter ((=="").snd) (readP_to_S parse str) of
    [(r, "")] -> r
    _ -> throwGhcException $ CmdLineError ("Can't parse -sig-of: " ++ str)
  where parse = Map.fromList <$> sepBy parseEntry (R.char ',')
        parseEntry = do
            n <- tok $ parseModuleName
            -- ToDo: deprecate this 'is' syntax?
            tok $ ((string "is" >> return ()) +++ (R.char '=' >> return ()))
            m <- tok $ parseModule
            return (n, m)
        parseModule = do
            pk <- munch1 (\c -> isAlphaNum c || c `elem` "-_")
            _ <- R.char ':'
            m <- parseModuleName
            return (mkModule (stringToPackageKey pk) m)
        tok m = skipSpaces >> m

setSigOf :: String -> DynFlags -> DynFlags
setSigOf s d = d { sigOf = parseSigOf s }

addPluginModuleName :: String -> DynFlags -> DynFlags
addPluginModuleName name d = d { pluginModNames = (mkModuleName name) : (pluginModNames d) }

addPluginModuleNameOption :: String -> DynFlags -> DynFlags
addPluginModuleNameOption optflag d = d { pluginModNameOpts = (mkModuleName m, option) : (pluginModNameOpts d) }
  where (m, rest) = break (== ':') optflag
        option = case rest of
          [] -> "" -- should probably signal an error
          (_:plug_opt) -> plug_opt -- ignore the ':' from break

parseDynLibLoaderMode f d =
 case splitAt 8 f of
   ("deploy", "")       -> d{ dynLibLoader = Deployable }
   ("sysdep", "")       -> d{ dynLibLoader = SystemDependent }
   _                    -> throwGhcException (CmdLineError ("Unknown dynlib loader: " ++ f))

setDumpPrefixForce f d = d { dumpPrefixForce = f}

-- XXX HACK: Prelude> words "'does not' work" ===> ["'does","not'","work"]
-- Config.hs should really use Option.
setPgmP   f = let (pgm:args) = words f in alterSettings (\s -> s { sPgm_P   = (pgm, map Option args)})
addOptl   f = alterSettings (\s -> s { sOpt_l   = f : sOpt_l s})
addOptc   f = alterSettings (\s -> s { sOpt_c   = f : sOpt_c s})
addOptP   f = alterSettings (\s -> s { sOpt_P   = f : sOpt_P s})


setDepMakefile :: FilePath -> DynFlags -> DynFlags
setDepMakefile f d = d { depMakefile = f }

setDepIncludePkgDeps :: Bool -> DynFlags -> DynFlags
setDepIncludePkgDeps b d = d { depIncludePkgDeps = b }

addDepExcludeMod :: String -> DynFlags -> DynFlags
addDepExcludeMod m d
    = d { depExcludeMods = mkModuleName m : depExcludeMods d }

addDepSuffix :: FilePath -> DynFlags -> DynFlags
addDepSuffix s d = d { depSuffixes = s : depSuffixes d }

addCmdlineFramework f d = d{ cmdlineFrameworks = f : cmdlineFrameworks d}

addHaddockOpts f d = d{ haddockOptions = Just f}

addGhciScript f d = d{ ghciScripts = f : ghciScripts d}

setInteractivePrint f d = d{ interactivePrint = Just f}

-- -----------------------------------------------------------------------------
-- Command-line options

-- | When invoking external tools as part of the compilation pipeline, we
-- pass these a sequence of options on the command-line. Rather than
-- just using a list of Strings, we use a type that allows us to distinguish
-- between filepaths and 'other stuff'. The reason for this is that
-- this type gives us a handle on transforming filenames, and filenames only,
-- to whatever format they're expected to be on a particular platform.
data Option
 = FileOption -- an entry that _contains_ filename(s) / filepaths.
              String  -- a non-filepath prefix that shouldn't be
                      -- transformed (e.g., "/out=")
              String  -- the filepath/filename portion
 | Option     String
 deriving ( Eq )

showOpt :: Option -> String
showOpt (FileOption pre f) = pre ++ f
showOpt (Option s)  = s

-----------------------------------------------------------------------------
-- Setting the optimisation level

updOptLevel :: Int -> DynFlags -> DynFlags
-- ^ Sets the 'DynFlags' to be appropriate to the optimisation level
updOptLevel n dfs
  = dfs2{ optLevel = final_n }
  where
   final_n = max 0 (min 2 n)    -- Clamp to 0 <= n <= 2
   dfs1 = foldr (flip gopt_unset) dfs  remove_gopts
   dfs2 = foldr (flip gopt_set)   dfs1 extra_gopts

   extra_gopts  = [ f | (ns,f) <- optLevelFlags, final_n `elem` ns ]
   remove_gopts = [ f | (ns,f) <- optLevelFlags, final_n `notElem` ns ]

-- -----------------------------------------------------------------------------
-- StgToDo:  abstraction of stg-to-stg passes to run.

data StgToDo
  = StgDoMassageForProfiling  -- should be (next to) last
  -- There's also setStgVarInfo, but its absolute "lastness"
  -- is so critical that it is hardwired in (no flag).
  | D_stg_stats

getStgToDo :: DynFlags -> [StgToDo]
getStgToDo dflags
  = todo2
  where
        stg_stats = gopt Opt_StgStats dflags

        todo1 = if stg_stats then [D_stg_stats] else []

        todo2 | WayProf `elem` ways dflags
              = StgDoMassageForProfiling : todo1
              | otherwise
              = todo1

{- **********************************************************************
%*                                                                      *
                DynFlags parser
%*                                                                      *
%********************************************************************* -}

-- -----------------------------------------------------------------------------
-- Parsing the dynamic flags.


-- | Parse dynamic flags from a list of command line arguments.  Returns the
-- the parsed 'DynFlags', the left-over arguments, and a list of warnings.
-- Throws a 'UsageError' if errors occurred during parsing (such as unknown
-- flags or missing arguments).
parseDynamicFlagsCmdLine :: MonadIO m => DynFlags -> [Located String]
                         -> m (DynFlags, [Located String], [Located String])
                            -- ^ Updated 'DynFlags', left-over arguments, and
                            -- list of warnings.
parseDynamicFlagsCmdLine = parseDynamicFlagsFull flagsAll True


-- | Like 'parseDynamicFlagsCmdLine' but does not allow the package flags
-- (-package, -hide-package, -ignore-package, -hide-all-packages, -package-db).
-- Used to parse flags set in a modules pragma.
parseDynamicFilePragma :: MonadIO m => DynFlags -> [Located String]
                       -> m (DynFlags, [Located String], [Located String])
                          -- ^ Updated 'DynFlags', left-over arguments, and
                          -- list of warnings.
parseDynamicFilePragma = parseDynamicFlagsFull flagsDynamic False


-- | Parses the dynamically set flags for GHC. This is the most general form of
-- the dynamic flag parser that the other methods simply wrap. It allows
-- saying which flags are valid flags and indicating if we are parsing
-- arguments from the command line or from a file pragma.
parseDynamicFlagsFull :: MonadIO m
                  => [Flag (CmdLineP DynFlags)]    -- ^ valid flags to match against
                  -> Bool                          -- ^ are the arguments from the command line?
                  -> DynFlags                      -- ^ current dynamic flags
                  -> [Located String]              -- ^ arguments to parse
                  -> m (DynFlags, [Located String], [Located String])
parseDynamicFlagsFull activeFlags cmdline dflags0 args = do
  let ((leftover, errs, warns), dflags1)
          = runCmdLine (processArgs activeFlags args) dflags0

  -- See Note [Handling errors when parsing commandline flags]
  unless (null errs) $ liftIO $ throwGhcExceptionIO $
      errorsToGhcException . map (showPpr dflags0 . getLoc &&& unLoc) $ errs

  -- check for disabled flags in safe haskell
  let (dflags2, sh_warns) = safeFlagCheck cmdline dflags1
      dflags3 = updateWays dflags2
      theWays = ways dflags3

  unless (allowed_combination theWays) $ liftIO $
      throwGhcExceptionIO (CmdLineError ("combination not supported: " ++
                               intercalate "/" (map wayDesc theWays)))

  let chooseOutput
        | isJust (outputFile dflags3)          -- Only iff user specified -o ...
        , not (isJust (dynOutputFile dflags3)) -- but not -dyno
        = return $ dflags3 { dynOutputFile = Just $ dynOut (fromJust $ outputFile dflags3) }
        | otherwise
        = return dflags3
        where
          dynOut = flip addExtension (dynObjectSuf dflags3) . dropExtension
  dflags4 <- ifGeneratingDynamicToo dflags3 chooseOutput (return dflags3)

  let (dflags5, consistency_warnings) = makeDynFlagsConsistent dflags4

  dflags6 <- case dllSplitFile dflags5 of
             Nothing -> return (dflags5 { dllSplit = Nothing })
             Just f ->
                 case dllSplit dflags5 of
                 Just _ ->
                     -- If dllSplit is out of date then it would have
                     -- been set to Nothing. As it's a Just, it must be
                     -- up-to-date.
                     return dflags5
                 Nothing ->
                     do xs <- liftIO $ readFile f
                        let ss = map (Set.fromList . words) (lines xs)
                        return $ dflags5 { dllSplit = Just ss }

  -- Set timer stats & heap size
  when (enableTimeStats dflags6) $ liftIO enableTimingStats
  case (ghcHeapSize dflags6) of
    Just x -> liftIO (setHeapSize x)
    _      -> return ()

  liftIO $ setUnsafeGlobalDynFlags dflags6

  return (dflags6, leftover, consistency_warnings ++ sh_warns ++ warns)

updateWays :: DynFlags -> DynFlags
updateWays dflags
    = let theWays = sort $ nub $ ways dflags
          f = if WayDyn `elem` theWays then unSetGeneralFlag'
                                       else setGeneralFlag'
      in f Opt_Static
       $ dflags {
             ways        = theWays,
             buildTag    = mkBuildTag (filter (not . wayRTSOnly) theWays),
             rtsBuildTag = mkBuildTag                            theWays
         }

-- | Check (and potentially disable) any extensions that aren't allowed
-- in safe mode.
--
-- The bool is to indicate if we are parsing command line flags (false means
-- file pragma). This allows us to generate better warnings.
safeFlagCheck :: Bool -> DynFlags -> (DynFlags, [Located String])
safeFlagCheck _ dflags | safeLanguageOn dflags = (dflagsUnset, warns)
  where
    -- Handle illegal flags under safe language.
    (dflagsUnset, warns) = foldl check_method (dflags, []) unsafeFlags

    check_method (df, warns) (str,loc,test,fix)
        | test df   = (fix df, warns ++ safeFailure (loc df) str)
        | otherwise = (df, warns)

    safeFailure loc str
       = [L loc $ str ++ " is not allowed in Safe Haskell; ignoring "
           ++ str]

safeFlagCheck cmdl dflags =
  case (safeInferOn dflags) of
    True | safeFlags -> (dflags', warn)
    True             -> (dflags' { safeInferred = False }, warn)
    False            -> (dflags', warn)

  where
    -- dynflags and warn for when -fpackage-trust by itself with no safe
    -- haskell flag
    (dflags', warn)
      | safeHaskell dflags == Sf_None && not cmdl && packageTrustOn dflags
      = (gopt_unset dflags Opt_PackageTrust, pkgWarnMsg)
      | otherwise = (dflags, [])

    pkgWarnMsg = [L (pkgTrustOnLoc dflags') $
                    "-fpackage-trust ignored;" ++
                    " must be specified with a Safe Haskell flag"]

    -- Have we inferred Unsafe? See Note [HscMain . Safe Haskell Inference]
    safeFlags = all (\(_,_,t,_) -> not $ t dflags) unsafeFlagsForInfer


{- **********************************************************************
%*                                                                      *
                DynFlags specifications
%*                                                                      *
%********************************************************************* -}

-- | All dynamic flags option strings. These are the user facing strings for
-- enabling and disabling options.
allFlags :: [String]
allFlags = [ '-':flagName flag
           | flag <- flagsAll
           , ok (flagOptKind flag) ]
  where ok (PrefixPred _ _) = False
        ok _   = True

{-
 - Below we export user facing symbols for GHC dynamic flags for use with the
 - GHC API.
 -}

-- All dynamic flags present in GHC.
flagsAll :: [Flag (CmdLineP DynFlags)]
flagsAll     = package_flags ++ dynamic_flags

-- All dynamic flags, minus package flags, present in GHC.
flagsDynamic :: [Flag (CmdLineP DynFlags)]
flagsDynamic = dynamic_flags

-- ALl package flags present in GHC.
flagsPackage :: [Flag (CmdLineP DynFlags)]
flagsPackage = package_flags

--------------- The main flags themselves ------------------
-- See Note [Updating flag description in the User's Guide]
-- See Note [Supporting CLI completion]
dynamic_flags :: [Flag (CmdLineP DynFlags)]
dynamic_flags = [
    defFlag "n"
      (NoArg (addWarn "The -n flag is deprecated and no longer has any effect"))
  , defFlag "cpp"      (NoArg (setExtensionFlag Opt_Cpp))
  , defFlag "F"        (NoArg (setGeneralFlag Opt_Pp))
  , defFlag "#include"
      (HasArg (\s -> do
         addCmdlineHCInclude s
         addWarn ("-#include and INCLUDE pragmas are " ++
                  "deprecated: They no longer have any effect")))
  , defFlag "v"        (OptIntSuffix setVerbosity)

  , defGhcFlag "j"     (OptIntSuffix (\n -> upd (\d -> d {parMakeCount = n})))
  , defFlag "sig-of"   (sepArg setSigOf)

    -- RTS options -------------------------------------------------------------
  , defFlag "H"           (HasArg (\s -> upd (\d ->
          d { ghcHeapSize = Just $ fromIntegral (decodeSize s)})))

  , defFlag "Rghc-timing" (NoArg (upd (\d -> d { enableTimeStats = True })))

    ------- ways ---------------------------------------------------------------
  , defGhcFlag "prof"           (NoArg (addWay WayProf))
  , defGhcFlag "eventlog"       (NoArg (addWay WayEventLog))
  , defGhcFlag "parallel"       (NoArg (addWay WayPar))
  , defGhcFlag "smp"
      (NoArg (addWay WayThreaded >> deprecate "Use -threaded instead"))
  , defGhcFlag "debug"          (NoArg (addWay WayDebug))
  , defGhcFlag "threaded"       (NoArg (addWay WayThreaded))

  , defGhcFlag "ticky"
      (NoArg (setGeneralFlag Opt_Ticky >> addWay WayDebug))

    -- -ticky enables ticky-ticky code generation, and also implies -debug which
    -- is required to get the RTS ticky support.

        ----- Linker --------------------------------------------------------
  , defGhcFlag "static"         (NoArg removeWayDyn)
  , defGhcFlag "dynamic"        (NoArg (addWay WayDyn))
  , defGhcFlag "rdynamic" $ noArg $
#ifdef linux_HOST_OS
                              addOptl "-rdynamic"
#elif defined (mingw32_HOST_OS)
                              addOptl "-export-all-symbols"
#else
    -- ignored for compat w/ gcc:
                              id
#endif
  , defGhcFlag "relative-dynlib-paths"
      (NoArg (setGeneralFlag Opt_RelativeDynlibPaths))

        ------- Specific phases  --------------------------------------------
    -- need to appear before -pgmL to be parsed as LLVM flags.
  , defFlag "pgmlo"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_lo  = (f,[])})))
  , defFlag "pgmlc"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_lc  = (f,[])})))
  , defFlag "pgmL"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_L   = f})))
  , defFlag "pgmP"
      (hasArg setPgmP)
  , defFlag "pgmF"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_F   = f})))
  , defFlag "pgmc"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_c   = (f,[])})))
  , defFlag "pgms"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_s   = (f,[])})))
  , defFlag "pgma"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_a   = (f,[])})))
  , defFlag "pgml"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_l   = (f,[])})))
  , defFlag "pgmdll"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_dll = (f,[])})))
  , defFlag "pgmwindres"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_windres = f})))
  , defFlag "pgmlibtool"
      (hasArg (\f -> alterSettings (\s -> s { sPgm_libtool = f})))

    -- need to appear before -optl/-opta to be parsed as LLVM flags.
  , defFlag "optlo"
      (hasArg (\f -> alterSettings (\s -> s { sOpt_lo  = f : sOpt_lo s})))
  , defFlag "optlc"
      (hasArg (\f -> alterSettings (\s -> s { sOpt_lc  = f : sOpt_lc s})))
  , defFlag "optL"
      (hasArg (\f -> alterSettings (\s -> s { sOpt_L   = f : sOpt_L s})))
  , defFlag "optP"
      (hasArg addOptP)
  , defFlag "optF"
      (hasArg (\f -> alterSettings (\s -> s { sOpt_F   = f : sOpt_F s})))
  , defFlag "optc"
      (hasArg addOptc)
  , defFlag "opta"
      (hasArg (\f -> alterSettings (\s -> s { sOpt_a   = f : sOpt_a s})))
  , defFlag "optl"
      (hasArg addOptl)
  , defFlag "optwindres"
      (hasArg (\f ->
        alterSettings (\s -> s { sOpt_windres = f : sOpt_windres s})))

  , defGhcFlag "split-objs"
      (NoArg (if can_split
                then setGeneralFlag Opt_SplitObjs
                else addWarn "ignoring -fsplit-objs"))

        -------- ghc -M -----------------------------------------------------
  , defGhcFlag "dep-suffix"               (hasArg addDepSuffix)
  , defGhcFlag "dep-makefile"             (hasArg setDepMakefile)
  , defGhcFlag "include-pkg-deps"         (noArg (setDepIncludePkgDeps True))
  , defGhcFlag "exclude-module"           (hasArg addDepExcludeMod)

        -------- Linking ----------------------------------------------------
  , defGhcFlag "no-link"            (noArg (\d -> d{ ghcLink=NoLink }))
  , defGhcFlag "shared"             (noArg (\d -> d{ ghcLink=LinkDynLib }))
  , defGhcFlag "staticlib"          (noArg (\d -> d{ ghcLink=LinkStaticLib }))
  , defGhcFlag "dynload"            (hasArg parseDynLibLoaderMode)
  , defGhcFlag "dylib-install-name" (hasArg setDylibInstallName)
    -- -dll-split is an internal flag, used only during the GHC build
  , defHiddenFlag "dll-split"
      (hasArg (\f d -> d{ dllSplitFile = Just f, dllSplit = Nothing }))

        ------- Libraries ---------------------------------------------------
  , defFlag "L"   (Prefix addLibraryPath)
  , defFlag "l"   (hasArg (addLdInputs . Option . ("-l" ++)))

        ------- Frameworks --------------------------------------------------
        -- -framework-path should really be -F ...
  , defFlag "framework-path" (HasArg addFrameworkPath)
  , defFlag "framework"      (hasArg addCmdlineFramework)

        ------- Output Redirection ------------------------------------------
  , defGhcFlag "odir"              (hasArg setObjectDir)
  , defGhcFlag "o"                 (sepArg (setOutputFile . Just))
  , defGhcFlag "dyno"              (sepArg (setDynOutputFile . Just))
  , defGhcFlag "ohi"               (hasArg (setOutputHi . Just ))
  , defGhcFlag "osuf"              (hasArg setObjectSuf)
  , defGhcFlag "dynosuf"           (hasArg setDynObjectSuf)
  , defGhcFlag "hcsuf"             (hasArg setHcSuf)
  , defGhcFlag "hisuf"             (hasArg setHiSuf)
  , defGhcFlag "dynhisuf"          (hasArg setDynHiSuf)
  , defGhcFlag "hidir"             (hasArg setHiDir)
  , defGhcFlag "tmpdir"            (hasArg setTmpDir)
  , defGhcFlag "stubdir"           (hasArg setStubDir)
  , defGhcFlag "dumpdir"           (hasArg setDumpDir)
  , defGhcFlag "outputdir"         (hasArg setOutputDir)
  , defGhcFlag "ddump-file-prefix" (hasArg (setDumpPrefixForce . Just))

  , defGhcFlag "dynamic-too"       (NoArg (setGeneralFlag Opt_BuildDynamicToo))

        ------- Keeping temporary files -------------------------------------
     -- These can be singular (think ghc -c) or plural (think ghc --make)
  , defGhcFlag "keep-hc-file"     (NoArg (setGeneralFlag Opt_KeepHcFiles))
  , defGhcFlag "keep-hc-files"    (NoArg (setGeneralFlag Opt_KeepHcFiles))
  , defGhcFlag "keep-s-file"      (NoArg (setGeneralFlag Opt_KeepSFiles))
  , defGhcFlag "keep-s-files"     (NoArg (setGeneralFlag Opt_KeepSFiles))
  , defGhcFlag "keep-llvm-file"   (NoArg (do setObjTarget HscLlvm
                                             setGeneralFlag Opt_KeepLlvmFiles))
  , defGhcFlag "keep-llvm-files"  (NoArg (do setObjTarget HscLlvm
                                             setGeneralFlag Opt_KeepLlvmFiles))
     -- This only makes sense as plural
  , defGhcFlag "keep-tmp-files"   (NoArg (setGeneralFlag Opt_KeepTmpFiles))

        ------- Miscellaneous ----------------------------------------------
  , defGhcFlag "no-auto-link-packages"
      (NoArg (unSetGeneralFlag Opt_AutoLinkPackages))
  , defGhcFlag "no-hs-main"     (NoArg (setGeneralFlag Opt_NoHsMain))
  , defGhcFlag "with-rtsopts"   (HasArg setRtsOpts)
  , defGhcFlag "rtsopts"        (NoArg (setRtsOptsEnabled RtsOptsAll))
  , defGhcFlag "rtsopts=all"    (NoArg (setRtsOptsEnabled RtsOptsAll))
  , defGhcFlag "rtsopts=some"   (NoArg (setRtsOptsEnabled RtsOptsSafeOnly))
  , defGhcFlag "rtsopts=none"   (NoArg (setRtsOptsEnabled RtsOptsNone))
  , defGhcFlag "no-rtsopts"     (NoArg (setRtsOptsEnabled RtsOptsNone))
  , defGhcFlag "no-rtsopts-suggestions"
      (noArg (\d -> d {rtsOptsSuggestions = False} ))
  , defGhcFlag "main-is"        (SepArg setMainIs)
  , defGhcFlag "haddock"        (NoArg (setGeneralFlag Opt_Haddock))
  , defGhcFlag "haddock-opts"   (hasArg addHaddockOpts)
  , defGhcFlag "hpcdir"         (SepArg setOptHpcDir)
  , defGhciFlag "ghci-script"    (hasArg addGhciScript)
  , defGhciFlag "interactive-print" (hasArg setInteractivePrint)
  , defGhcFlag "ticky-allocd"      (NoArg (setGeneralFlag Opt_Ticky_Allocd))
  , defGhcFlag "ticky-LNE"         (NoArg (setGeneralFlag Opt_Ticky_LNE))
  , defGhcFlag "ticky-dyn-thunk"   (NoArg (setGeneralFlag Opt_Ticky_Dyn_Thunk))
        ------- recompilation checker --------------------------------------
  , defGhcFlag "recomp"   (NoArg (do unSetGeneralFlag Opt_ForceRecomp
                                     deprecate "Use -fno-force-recomp instead"))
  , defGhcFlag "no-recomp" (NoArg (do setGeneralFlag Opt_ForceRecomp
                                      deprecate "Use -fforce-recomp instead"))

        ------ HsCpp opts ---------------------------------------------------
  , defFlag "D"              (AnySuffix (upd . addOptP))
  , defFlag "U"              (AnySuffix (upd . addOptP))

        ------- Include/Import Paths ----------------------------------------
  , defFlag "I"              (Prefix    addIncludePath)
  , defFlag "i"              (OptPrefix addImportPath)

        ------ Output style options -----------------------------------------
  , defFlag "dppr-user-length" (intSuffix (\n d -> d{ pprUserLength = n }))
  , defFlag "dppr-cols"        (intSuffix (\n d -> d{ pprCols = n }))
  , defGhcFlag "dtrace-level"  (intSuffix (\n d -> d{ traceLevel = n }))
  -- Suppress all that is suppressable in core dumps.
  -- Except for uniques, as some simplifier phases introduce new varibles that
  -- have otherwise identical names.
  , defGhcFlag "dsuppress-all"
      (NoArg $ do setGeneralFlag Opt_SuppressCoercions
                  setGeneralFlag Opt_SuppressVarKinds
                  setGeneralFlag Opt_SuppressModulePrefixes
                  setGeneralFlag Opt_SuppressTypeApplications
                  setGeneralFlag Opt_SuppressIdInfo
                  setGeneralFlag Opt_SuppressTypeSignatures)

        ------ Debugging ----------------------------------------------------
  , defGhcFlag "dstg-stats"              (NoArg (setGeneralFlag Opt_StgStats))

  , defGhcFlag "ddump-cmm"               (setDumpFlag Opt_D_dump_cmm)
  , defGhcFlag "ddump-cmm-raw"           (setDumpFlag Opt_D_dump_cmm_raw)
  , defGhcFlag "ddump-cmm-cfg"           (setDumpFlag Opt_D_dump_cmm_cfg)
  , defGhcFlag "ddump-cmm-cbe"           (setDumpFlag Opt_D_dump_cmm_cbe)
  , defGhcFlag "ddump-cmm-switch"        (setDumpFlag Opt_D_dump_cmm_switch)
  , defGhcFlag "ddump-cmm-proc"          (setDumpFlag Opt_D_dump_cmm_proc)
  , defGhcFlag "ddump-cmm-sink"          (setDumpFlag Opt_D_dump_cmm_sink)
  , defGhcFlag "ddump-cmm-sp"            (setDumpFlag Opt_D_dump_cmm_sp)
  , defGhcFlag "ddump-cmm-procmap"       (setDumpFlag Opt_D_dump_cmm_procmap)
  , defGhcFlag "ddump-cmm-split"         (setDumpFlag Opt_D_dump_cmm_split)
  , defGhcFlag "ddump-cmm-info"          (setDumpFlag Opt_D_dump_cmm_info)
  , defGhcFlag "ddump-cmm-cps"           (setDumpFlag Opt_D_dump_cmm_cps)
  , defGhcFlag "ddump-core-stats"        (setDumpFlag Opt_D_dump_core_stats)
  , defGhcFlag "ddump-asm"               (setDumpFlag Opt_D_dump_asm)
  , defGhcFlag "ddump-asm-native"        (setDumpFlag Opt_D_dump_asm_native)
  , defGhcFlag "ddump-asm-liveness"      (setDumpFlag Opt_D_dump_asm_liveness)
  , defGhcFlag "ddump-asm-regalloc"      (setDumpFlag Opt_D_dump_asm_regalloc)
  , defGhcFlag "ddump-asm-conflicts"     (setDumpFlag Opt_D_dump_asm_conflicts)
  , defGhcFlag "ddump-asm-regalloc-stages"
      (setDumpFlag Opt_D_dump_asm_regalloc_stages)
  , defGhcFlag "ddump-asm-stats"         (setDumpFlag Opt_D_dump_asm_stats)
  , defGhcFlag "ddump-asm-expanded"      (setDumpFlag Opt_D_dump_asm_expanded)
  , defGhcFlag "ddump-llvm"            (NoArg (do setObjTarget HscLlvm
                                                  setDumpFlag' Opt_D_dump_llvm))
  , defGhcFlag "ddump-deriv"             (setDumpFlag Opt_D_dump_deriv)
  , defGhcFlag "ddump-ds"                (setDumpFlag Opt_D_dump_ds)
  , defGhcFlag "ddump-foreign"           (setDumpFlag Opt_D_dump_foreign)
  , defGhcFlag "ddump-inlinings"         (setDumpFlag Opt_D_dump_inlinings)
  , defGhcFlag "ddump-rule-firings"      (setDumpFlag Opt_D_dump_rule_firings)
  , defGhcFlag "ddump-rule-rewrites"     (setDumpFlag Opt_D_dump_rule_rewrites)
  , defGhcFlag "ddump-simpl-trace"       (setDumpFlag Opt_D_dump_simpl_trace)
  , defGhcFlag "ddump-occur-anal"        (setDumpFlag Opt_D_dump_occur_anal)
  , defGhcFlag "ddump-parsed"            (setDumpFlag Opt_D_dump_parsed)
  , defGhcFlag "ddump-rn"                (setDumpFlag Opt_D_dump_rn)
  , defGhcFlag "ddump-simpl"             (setDumpFlag Opt_D_dump_simpl)
  , defGhcFlag "ddump-simpl-iterations"
      (setDumpFlag Opt_D_dump_simpl_iterations)
  , defGhcFlag "ddump-spec"              (setDumpFlag Opt_D_dump_spec)
  , defGhcFlag "ddump-prep"              (setDumpFlag Opt_D_dump_prep)
  , defGhcFlag "ddump-stg"               (setDumpFlag Opt_D_dump_stg)
  , defGhcFlag "ddump-call-arity"        (setDumpFlag Opt_D_dump_call_arity)
  , defGhcFlag "ddump-stranal"           (setDumpFlag Opt_D_dump_stranal)
  , defGhcFlag "ddump-strsigs"           (setDumpFlag Opt_D_dump_strsigs)
  , defGhcFlag "ddump-tc"                (setDumpFlag Opt_D_dump_tc)
  , defGhcFlag "ddump-types"             (setDumpFlag Opt_D_dump_types)
  , defGhcFlag "ddump-rules"             (setDumpFlag Opt_D_dump_rules)
  , defGhcFlag "ddump-cse"               (setDumpFlag Opt_D_dump_cse)
  , defGhcFlag "ddump-worker-wrapper"    (setDumpFlag Opt_D_dump_worker_wrapper)
  , defGhcFlag "ddump-rn-trace"          (setDumpFlag Opt_D_dump_rn_trace)
  , defGhcFlag "ddump-if-trace"          (setDumpFlag Opt_D_dump_if_trace)
  , defGhcFlag "ddump-cs-trace"          (setDumpFlag Opt_D_dump_cs_trace)
  , defGhcFlag "ddump-tc-trace"          (NoArg (do
                                            setDumpFlag' Opt_D_dump_tc_trace
                                            setDumpFlag' Opt_D_dump_cs_trace))
  , defGhcFlag "ddump-vt-trace"          (setDumpFlag Opt_D_dump_vt_trace)
  , defGhcFlag "ddump-splices"           (setDumpFlag Opt_D_dump_splices)
  , defGhcFlag "dth-dec-file"            (setDumpFlag Opt_D_th_dec_file)

  , defGhcFlag "ddump-rn-stats"          (setDumpFlag Opt_D_dump_rn_stats)
  , defGhcFlag "ddump-opt-cmm"           (setDumpFlag Opt_D_dump_opt_cmm)
  , defGhcFlag "ddump-simpl-stats"       (setDumpFlag Opt_D_dump_simpl_stats)
  , defGhcFlag "ddump-bcos"              (setDumpFlag Opt_D_dump_BCOs)
  , defGhcFlag "dsource-stats"           (setDumpFlag Opt_D_source_stats)
  , defGhcFlag "dverbose-core2core"      (NoArg (do setVerbosity (Just 2)
                                                    setVerboseCore2Core))
  , defGhcFlag "dverbose-stg2stg"        (setDumpFlag Opt_D_verbose_stg2stg)
  , defGhcFlag "ddump-hi"                (setDumpFlag Opt_D_dump_hi)
  , defGhcFlag "ddump-minimal-imports"
      (NoArg (setGeneralFlag Opt_D_dump_minimal_imports))
  , defGhcFlag "ddump-vect"              (setDumpFlag Opt_D_dump_vect)
  , defGhcFlag "ddump-hpc"
      (setDumpFlag Opt_D_dump_ticked) -- back compat
  , defGhcFlag "ddump-ticked"            (setDumpFlag Opt_D_dump_ticked)
  , defGhcFlag "ddump-mod-cycles"        (setDumpFlag Opt_D_dump_mod_cycles)
  , defGhcFlag "ddump-mod-map"           (setDumpFlag Opt_D_dump_mod_map)
  , defGhcFlag "ddump-view-pattern-commoning"
      (setDumpFlag Opt_D_dump_view_pattern_commoning)
  , defGhcFlag "ddump-to-file"           (NoArg (setGeneralFlag Opt_DumpToFile))
  , defGhcFlag "ddump-hi-diffs"          (setDumpFlag Opt_D_dump_hi_diffs)
  , defGhcFlag "ddump-rtti"              (setDumpFlag Opt_D_dump_rtti)
  , defGhcFlag "dcore-lint"
      (NoArg (setGeneralFlag Opt_DoCoreLinting))
  , defGhcFlag "dstg-lint"
      (NoArg (setGeneralFlag Opt_DoStgLinting))
  , defGhcFlag "dcmm-lint"
      (NoArg (setGeneralFlag Opt_DoCmmLinting))
  , defGhcFlag "dasm-lint"
      (NoArg (setGeneralFlag Opt_DoAsmLinting))
  , defGhcFlag "dannot-lint"
      (NoArg (setGeneralFlag Opt_DoAnnotationLinting))
  , defGhcFlag "dshow-passes"            (NoArg (do forceRecompile
                                                    setVerbosity $ Just 2))
  , defGhcFlag "dfaststring-stats"
      (NoArg (setGeneralFlag Opt_D_faststring_stats))
  , defGhcFlag "dno-llvm-mangler"
      (NoArg (setGeneralFlag Opt_NoLlvmMangler)) -- hidden flag
  , defGhcFlag "ddump-debug"             (setDumpFlag Opt_D_dump_debug)

        ------ Machine dependant (-m<blah>) stuff ---------------------------

  , defGhcFlag "msse"         (noArg (\d -> d{ sseVersion = Just SSE1 }))
  , defGhcFlag "msse2"        (noArg (\d -> d{ sseVersion = Just SSE2 }))
  , defGhcFlag "msse3"        (noArg (\d -> d{ sseVersion = Just SSE3 }))
  , defGhcFlag "msse4"        (noArg (\d -> d{ sseVersion = Just SSE4 }))
  , defGhcFlag "msse4.2"      (noArg (\d -> d{ sseVersion = Just SSE42 }))
  , defGhcFlag "mavx"         (noArg (\d -> d{ avx = True }))
  , defGhcFlag "mavx2"        (noArg (\d -> d{ avx2 = True }))
  , defGhcFlag "mavx512cd"    (noArg (\d -> d{ avx512cd = True }))
  , defGhcFlag "mavx512er"    (noArg (\d -> d{ avx512er = True }))
  , defGhcFlag "mavx512f"     (noArg (\d -> d{ avx512f = True }))
  , defGhcFlag "mavx512pf"    (noArg (\d -> d{ avx512pf = True }))

     ------ Warning opts -------------------------------------------------
  , defFlag "W"      (NoArg (mapM_ setWarningFlag minusWOpts))
  , defFlag "Werror" (NoArg (setGeneralFlag           Opt_WarnIsError))
  , defFlag "Wwarn"  (NoArg (unSetGeneralFlag         Opt_WarnIsError))
  , defFlag "Wall"   (NoArg (mapM_ setWarningFlag minusWallOpts))
  , defFlag "Wnot"   (NoArg (do upd (\dfs -> dfs {warningFlags = IntSet.empty})
                                deprecate "Use -w instead"))
  , defFlag "w"      (NoArg (upd (\dfs -> dfs {warningFlags = IntSet.empty})))

        ------ Plugin flags ------------------------------------------------
  , defGhcFlag "fplugin-opt" (hasArg addPluginModuleNameOption)
  , defGhcFlag "fplugin"     (hasArg addPluginModuleName)

        ------ Optimisation flags ------------------------------------------
  , defGhcFlag "O"      (noArgM (setOptLevel 1))
  , defGhcFlag "Onot"   (noArgM (\dflags -> do deprecate "Use -O0 instead"
                                               setOptLevel 0 dflags))
  , defGhcFlag "Odph"   (noArgM setDPHOpt)
  , defGhcFlag "O"      (optIntSuffixM (\mb_n -> setOptLevel (mb_n `orElse` 1)))
                -- If the number is missing, use 1


  , defFlag "fmax-relevant-binds"
      (intSuffix (\n d -> d{ maxRelevantBinds = Just n }))
  , defFlag "fno-max-relevant-binds"
      (noArg (\d -> d{ maxRelevantBinds = Nothing }))
  , defFlag "fsimplifier-phases"
      (intSuffix (\n d -> d{ simplPhases = n }))
  , defFlag "fmax-simplifier-iterations"
      (intSuffix (\n d -> d{ maxSimplIterations = n }))
  , defFlag "fsimpl-tick-factor"
      (intSuffix (\n d -> d{ simplTickFactor = n }))
  , defFlag "fspec-constr-threshold"
      (intSuffix (\n d -> d{ specConstrThreshold = Just n }))
  , defFlag "fno-spec-constr-threshold"
      (noArg (\d -> d{ specConstrThreshold = Nothing }))
  , defFlag "fspec-constr-count"
      (intSuffix (\n d -> d{ specConstrCount = Just n }))
  , defFlag "fno-spec-constr-count"
      (noArg (\d -> d{ specConstrCount = Nothing }))
  , defFlag "fspec-constr-recursive"
      (intSuffix (\n d -> d{ specConstrRecursive = n }))
  , defFlag "fliberate-case-threshold"
      (intSuffix (\n d -> d{ liberateCaseThreshold = Just n }))
  , defFlag "fno-liberate-case-threshold"
      (noArg (\d -> d{ liberateCaseThreshold = Nothing }))
  , defFlag "frule-check"
      (sepArg (\s d -> d{ ruleCheck = Just s }))
  , defFlag "freduction-depth"
      (intSuffix (\n d -> d{ reductionDepth = treatZeroAsInf n }))
  , defFlag "fconstraint-solver-iterations"
      (intSuffix (\n d -> d{ solverIterations = treatZeroAsInf n }))
  , defFlag "fcontext-stack"
      (intSuffixM (\n d ->
       do { deprecate $ "use -freduction-depth=" ++ show n ++ " instead"
          ; return $ d{ reductionDepth = treatZeroAsInf n } }))
  , defFlag "ftype-function-depth"
      (intSuffixM (\n d ->
       do { deprecate $ "use -freduction-depth=" ++ show n ++ " instead"
          ; return $ d{ reductionDepth = treatZeroAsInf n } }))
  , defFlag "fstrictness-before"
      (intSuffix (\n d -> d{ strictnessBefore = n : strictnessBefore d }))
  , defFlag "ffloat-lam-args"
      (intSuffix (\n d -> d{ floatLamArgs = Just n }))
  , defFlag "ffloat-all-lams"
      (noArg (\d -> d{ floatLamArgs = Nothing }))

  , defFlag "fhistory-size"           (intSuffix (\n d -> d{ historySize = n }))

  , defFlag "funfolding-creation-threshold"
      (intSuffix   (\n d -> d {ufCreationThreshold = n}))
  , defFlag "funfolding-use-threshold"
      (intSuffix   (\n d -> d {ufUseThreshold = n}))
  , defFlag "funfolding-fun-discount"
      (intSuffix   (\n d -> d {ufFunAppDiscount = n}))
  , defFlag "funfolding-dict-discount"
      (intSuffix   (\n d -> d {ufDictDiscount = n}))
  , defFlag "funfolding-keeness-factor"
      (floatSuffix (\n d -> d {ufKeenessFactor = n}))

  , defFlag "fmax-worker-args" (intSuffix (\n d -> d {maxWorkerArgs = n}))

  , defGhciFlag "fghci-hist-size" (intSuffix (\n d -> d {ghciHistSize = n}))
  , defGhcFlag "fmax-inline-alloc-size"
      (intSuffix (\n d -> d{ maxInlineAllocSize = n }))
  , defGhcFlag "fmax-inline-memcpy-insns"
      (intSuffix (\n d -> d{ maxInlineMemcpyInsns = n }))
  , defGhcFlag "fmax-inline-memset-insns"
      (intSuffix (\n d -> d{ maxInlineMemsetInsns = n }))

        ------ Profiling ----------------------------------------------------

        -- OLD profiling flags
  , defGhcFlag "auto-all"    (noArg (\d -> d { profAuto = ProfAutoAll } ))
  , defGhcFlag "no-auto-all" (noArg (\d -> d { profAuto = NoProfAuto } ))
  , defGhcFlag "auto"        (noArg (\d -> d { profAuto = ProfAutoExports } ))
  , defGhcFlag "no-auto"     (noArg (\d -> d { profAuto = NoProfAuto } ))
  , defGhcFlag "caf-all"
      (NoArg (setGeneralFlag Opt_AutoSccsOnIndividualCafs))
  , defGhcFlag "no-caf-all"
      (NoArg (unSetGeneralFlag Opt_AutoSccsOnIndividualCafs))

        -- NEW profiling flags
  , defGhcFlag "fprof-auto"
      (noArg (\d -> d { profAuto = ProfAutoAll } ))
  , defGhcFlag "fprof-auto-top"
      (noArg (\d -> d { profAuto = ProfAutoTop } ))
  , defGhcFlag "fprof-auto-exported"
      (noArg (\d -> d { profAuto = ProfAutoExports } ))
  , defGhcFlag "fprof-auto-calls"
      (noArg (\d -> d { profAuto = ProfAutoCalls } ))
  , defGhcFlag "fno-prof-auto"
      (noArg (\d -> d { profAuto = NoProfAuto } ))

        ------ Compiler flags -----------------------------------------------

  , defGhcFlag "fasm"             (NoArg (setObjTarget HscAsm))
  , defGhcFlag "fvia-c"           (NoArg
         (addWarn $ "The -fvia-c flag does nothing; " ++
                    "it will be removed in a future GHC release"))
  , defGhcFlag "fvia-C"           (NoArg
         (addWarn $ "The -fvia-C flag does nothing; " ++
                    "it will be removed in a future GHC release"))
  , defGhcFlag "fllvm"            (NoArg (setObjTarget HscLlvm))

  , defFlag "fno-code"         (NoArg (do upd $ \d -> d{ ghcLink=NoLink }
                                          setTarget HscNothing))
  , defFlag "fbyte-code"       (NoArg (setTarget HscInterpreted))
  , defFlag "fobject-code"     (NoArg (setTargetWithPlatform defaultHscTarget))
  , defFlag "fglasgow-exts"
      (NoArg (do enableGlasgowExts
                 deprecate "Use individual extensions instead"))
  , defFlag "fno-glasgow-exts"
      (NoArg (do disableGlasgowExts
                 deprecate "Use individual extensions instead"))
  , defFlag "fwarn-unused-binds" (NoArg enableUnusedBinds)
  , defFlag "fno-warn-unused-binds" (NoArg disableUnusedBinds)

        ------ Safe Haskell flags -------------------------------------------
  , defFlag "fpackage-trust"   (NoArg setPackageTrust)
  , defFlag "fno-safe-infer"   (noArg (\d -> d { safeInfer = False  } ))
  , defGhcFlag "fPIC"          (NoArg (setGeneralFlag Opt_PIC))
  , defGhcFlag "fno-PIC"       (NoArg (unSetGeneralFlag Opt_PIC))

         ------ Debugging flags ----------------------------------------------
  , defGhcFlag "g"             (NoArg (setGeneralFlag Opt_Debug))
 ]
 ++ map (mkFlag turnOn  ""     setGeneralFlag  ) negatableFlags
 ++ map (mkFlag turnOff "no-"  unSetGeneralFlag) negatableFlags
 ++ map (mkFlag turnOn  "d"    setGeneralFlag  ) dFlags
 ++ map (mkFlag turnOff "dno-" unSetGeneralFlag) dFlags
 ++ map (mkFlag turnOn  "f"    setGeneralFlag  ) fFlags
 ++ map (mkFlag turnOff "fno-" unSetGeneralFlag) fFlags
 ++ map (mkFlag turnOn  "f"    setWarningFlag  ) fWarningFlags
 ++ map (mkFlag turnOff "fno-" unSetWarningFlag) fWarningFlags
 ++ map (mkFlag turnOn  "f"    setExtensionFlag  ) fLangFlags
 ++ map (mkFlag turnOff "fno-" unSetExtensionFlag) fLangFlags
 ++ map (mkFlag turnOn  "X"    setExtensionFlag  ) xFlags
 ++ map (mkFlag turnOff "XNo"  unSetExtensionFlag) xFlags
 ++ map (mkFlag turnOn  "X"    setLanguage) languageFlags
 ++ map (mkFlag turnOn  "X"    setSafeHaskell) safeHaskellFlags
 ++ [ defFlag "XGenerics"
        (NoArg (deprecate $
                  "it does nothing; look into -XDefaultSignatures " ++
                  "and -XDeriveGeneric for generic programming support."))
    , defFlag "XNoGenerics"
        (NoArg (deprecate $
                  "it does nothing; look into -XDefaultSignatures and " ++
                  "-XDeriveGeneric for generic programming support.")) ]

-- See Note [Supporting CLI completion]
package_flags :: [Flag (CmdLineP DynFlags)]
package_flags = [
        ------- Packages ----------------------------------------------------
    defFlag "package-db"            (HasArg (addPkgConfRef . PkgConfFile))
  , defFlag "clear-package-db"      (NoArg clearPkgConf)
  , defFlag "no-global-package-db"  (NoArg removeGlobalPkgConf)
  , defFlag "no-user-package-db"    (NoArg removeUserPkgConf)
  , defFlag "global-package-db"     (NoArg (addPkgConfRef GlobalPkgConf))
  , defFlag "user-package-db"       (NoArg (addPkgConfRef UserPkgConf))

    -- backwards compat with GHC<=7.4 :
  , defFlag "package-conf"          (HasArg $ \path -> do
                                       addPkgConfRef (PkgConfFile path)
                                       deprecate "Use -package-db instead")
  , defFlag "no-user-package-conf"
      (NoArg $ do removeUserPkgConf
                  deprecate "Use -no-user-package-db instead")

  , defGhcFlag "package-name"      (HasArg $ \name -> do
                                      upd (setPackageKey name)
                                      deprecate "Use -this-package-key instead")
  , defGhcFlag "this-package-key"   (hasArg setPackageKey)
  , defFlag "package-id"            (HasArg exposePackageId)
  , defFlag "package"               (HasArg exposePackage)
  , defFlag "package-key"           (HasArg exposePackageKey)
  , defFlag "hide-package"          (HasArg hidePackage)
  , defFlag "hide-all-packages"     (NoArg (setGeneralFlag Opt_HideAllPackages))
  , defFlag "package-env"           (HasArg setPackageEnv)
  , defFlag "ignore-package"        (HasArg ignorePackage)
  , defFlag "syslib"
      (HasArg (\s -> do exposePackage s
                        deprecate "Use -package instead"))
  , defFlag "distrust-all-packages"
      (NoArg (setGeneralFlag Opt_DistrustAllPackages))
  , defFlag "trust"                 (HasArg trustPackage)
  , defFlag "distrust"              (HasArg distrustPackage)
  ]
  where
    setPackageEnv env = upd $ \s -> s { packageEnv = Just env }

-- | Make a list of flags for shell completion.
-- Filter all available flags into two groups, for interactive GHC vs all other.
flagsForCompletion :: Bool -> [String]
flagsForCompletion isInteractive
    = [ '-':flagName flag
      | flag <- flagsAll
      , modeFilter (flagGhcMode flag)
      ]
    where
      modeFilter AllModes = True
      modeFilter OnlyGhci = isInteractive
      modeFilter OnlyGhc = not isInteractive
      modeFilter HiddenFlag = False

type TurnOnFlag = Bool   -- True  <=> we are turning the flag on
                         -- False <=> we are turning the flag off
turnOn  :: TurnOnFlag; turnOn  = True
turnOff :: TurnOnFlag; turnOff = False

data FlagSpec flag
   = FlagSpec
       { flagSpecName :: String   -- ^ Flag in string form
       , flagSpecFlag :: flag     -- ^ Flag in internal form
       , flagSpecAction :: (TurnOnFlag -> DynP ())
           -- ^ Extra action to run when the flag is found
           -- Typically, emit a warning or error
       , flagSpecGhcMode :: GhcFlagMode
           -- ^ In which ghc mode the flag has effect
       }

-- | Define a new flag.
flagSpec :: String -> flag -> FlagSpec flag
flagSpec name flag = flagSpec' name flag nop

-- | Define a new flag with an effect.
flagSpec' :: String -> flag -> (TurnOnFlag -> DynP ()) -> FlagSpec flag
flagSpec' name flag act = FlagSpec name flag act AllModes

-- | Define a new flag for GHCi.
flagGhciSpec :: String -> flag -> FlagSpec flag
flagGhciSpec name flag = flagGhciSpec' name flag nop

-- | Define a new flag for GHCi with an effect.
flagGhciSpec' :: String -> flag -> (TurnOnFlag -> DynP ()) -> FlagSpec flag
flagGhciSpec' name flag act = FlagSpec name flag act OnlyGhci

-- | Define a new flag invisible to CLI completion.
flagHiddenSpec :: String -> flag -> FlagSpec flag
flagHiddenSpec name flag = flagHiddenSpec' name flag nop

-- | Define a new flag invisible to CLI completion with an effect.
flagHiddenSpec' :: String -> flag -> (TurnOnFlag -> DynP ()) -> FlagSpec flag
flagHiddenSpec' name flag act = FlagSpec name flag act HiddenFlag

mkFlag :: TurnOnFlag            -- ^ True <=> it should be turned on
       -> String                -- ^ The flag prefix
       -> (flag -> DynP ())     -- ^ What to do when the flag is found
       -> FlagSpec flag         -- ^ Specification of this particular flag
       -> Flag (CmdLineP DynFlags)
mkFlag turn_on flagPrefix f (FlagSpec name flag extra_action mode)
    = Flag (flagPrefix ++ name) (NoArg (f flag >> extra_action turn_on)) mode

deprecatedForExtension :: String -> TurnOnFlag -> DynP ()
deprecatedForExtension lang turn_on
    = deprecate ("use -X"  ++ flag ++
                 " or pragma {-# LANGUAGE " ++ flag ++ " #-} instead")
    where
      flag | turn_on    = lang
           | otherwise = "No"++lang

useInstead :: String -> TurnOnFlag -> DynP ()
useInstead flag turn_on
  = deprecate ("Use -f" ++ no ++ flag ++ " instead")
  where
    no = if turn_on then "" else "no-"

nop :: TurnOnFlag -> DynP ()
nop _ = return ()

-- | These @-f\<blah\>@ flags can all be reversed with @-fno-\<blah\>@
fWarningFlags :: [FlagSpec WarningFlag]
fWarningFlags = [
-- See Note [Updating flag description in the User's Guide]
-- See Note [Supporting CLI completion]
-- Please keep the list of flags below sorted alphabetically
  flagSpec "warn-alternative-layout-rule-transitional"
                                      Opt_WarnAlternativeLayoutRuleTransitional,
  flagSpec' "warn-amp"                        Opt_WarnAMP
    (\_ -> deprecate "it has no effect, and will be removed in GHC 7.12"),
  flagSpec "warn-auto-orphans"                Opt_WarnAutoOrphans,
  flagSpec "warn-deferred-type-errors"        Opt_WarnDeferredTypeErrors,
  flagSpec "warn-deprecations"                Opt_WarnWarningsDeprecations,
  flagSpec "warn-deprecated-flags"            Opt_WarnDeprecatedFlags,
  flagSpec "warn-deriving-typeable"           Opt_WarnDerivingTypeable,
  flagSpec "warn-dodgy-exports"               Opt_WarnDodgyExports,
  flagSpec "warn-dodgy-foreign-imports"       Opt_WarnDodgyForeignImports,
  flagSpec "warn-dodgy-imports"               Opt_WarnDodgyImports,
  flagSpec "warn-empty-enumerations"          Opt_WarnEmptyEnumerations,
  flagSpec "warn-context-quantification"      Opt_WarnContextQuantification,
  flagSpec' "warn-duplicate-constraints"      Opt_WarnDuplicateConstraints
    (\_ -> deprecate "it is subsumed by -fwarn-redundant-constraints"),
  flagSpec "warn-redundant-constraints"       Opt_WarnRedundantConstraints,
  flagSpec "warn-duplicate-exports"           Opt_WarnDuplicateExports,
  flagSpec "warn-hi-shadowing"                Opt_WarnHiShadows,
  flagSpec "warn-implicit-prelude"            Opt_WarnImplicitPrelude,
  flagSpec "warn-incomplete-patterns"         Opt_WarnIncompletePatterns,
  flagSpec "warn-incomplete-record-updates"   Opt_WarnIncompletePatternsRecUpd,
  flagSpec "warn-incomplete-uni-patterns"     Opt_WarnIncompleteUniPatterns,
  flagSpec "warn-inline-rule-shadowing"       Opt_WarnInlineRuleShadowing,
  flagSpec "warn-identities"                  Opt_WarnIdentities,
  flagSpec "warn-missing-fields"              Opt_WarnMissingFields,
  flagSpec "warn-missing-import-lists"        Opt_WarnMissingImportList,
  flagSpec "warn-missing-local-sigs"          Opt_WarnMissingLocalSigs,
  flagSpec "warn-missing-methods"             Opt_WarnMissingMethods,
  flagSpec "warn-missing-signatures"          Opt_WarnMissingSigs,
  flagSpec "warn-missing-exported-sigs"       Opt_WarnMissingExportedSigs,
  flagSpec "warn-monomorphism-restriction"    Opt_WarnMonomorphism,
  flagSpec "warn-name-shadowing"              Opt_WarnNameShadowing,
  flagSpec "warn-orphans"                     Opt_WarnOrphans,
  flagSpec "warn-overflowed-literals"         Opt_WarnOverflowedLiterals,
  flagSpec "warn-overlapping-patterns"        Opt_WarnOverlappingPatterns,
  flagSpec "warn-pointless-pragmas"           Opt_WarnPointlessPragmas,
  flagSpec' "warn-safe"                       Opt_WarnSafe setWarnSafe,
  flagSpec "warn-trustworthy-safe"            Opt_WarnTrustworthySafe,
  flagSpec "warn-tabs"                        Opt_WarnTabs,
  flagSpec "warn-type-defaults"               Opt_WarnTypeDefaults,
  flagSpec "warn-typed-holes"                 Opt_WarnTypedHoles,
  flagSpec "warn-partial-type-signatures"     Opt_WarnPartialTypeSignatures,
  flagSpec "warn-unrecognised-pragmas"        Opt_WarnUnrecognisedPragmas,
  flagSpec' "warn-unsafe"                     Opt_WarnUnsafe setWarnUnsafe,
  flagSpec "warn-unsupported-calling-conventions"
                                         Opt_WarnUnsupportedCallingConventions,
  flagSpec "warn-unsupported-llvm-version"    Opt_WarnUnsupportedLlvmVersion,
  flagSpec "warn-unticked-promoted-constructors"
                                         Opt_WarnUntickedPromotedConstructors,
  flagSpec "warn-unused-do-bind"              Opt_WarnUnusedDoBind,
  flagSpec "warn-unused-imports"              Opt_WarnUnusedImports,
  flagSpec "warn-unused-local-binds"          Opt_WarnUnusedLocalBinds,
  flagSpec "warn-unused-matches"              Opt_WarnUnusedMatches,
  flagSpec "warn-unused-pattern-binds"        Opt_WarnUnusedPatternBinds,
  flagSpec "warn-unused-top-binds"            Opt_WarnUnusedTopBinds,
  flagSpec "warn-warnings-deprecations"       Opt_WarnWarningsDeprecations,
  flagSpec "warn-wrong-do-bind"               Opt_WarnWrongDoBind]

-- | These @-\<blah\>@ flags can all be reversed with @-no-\<blah\>@
negatableFlags :: [FlagSpec GeneralFlag]
negatableFlags = [
  flagGhciSpec "ignore-dot-ghci"              Opt_IgnoreDotGhci ]

-- | These @-d\<blah\>@ flags can all be reversed with @-dno-\<blah\>@
dFlags :: [FlagSpec GeneralFlag]
dFlags = [
-- See Note [Updating flag description in the User's Guide]
-- See Note [Supporting CLI completion]
-- Please keep the list of flags below sorted alphabetically
  flagSpec "ppr-case-as-let"            Opt_PprCaseAsLet,
  flagSpec "ppr-ticks"                  Opt_PprShowTicks,
  flagSpec "suppress-coercions"         Opt_SuppressCoercions,
  flagSpec "suppress-idinfo"            Opt_SuppressIdInfo,
  flagSpec "suppress-module-prefixes"   Opt_SuppressModulePrefixes,
  flagSpec "suppress-type-applications" Opt_SuppressTypeApplications,
  flagSpec "suppress-type-signatures"   Opt_SuppressTypeSignatures,
  flagSpec "suppress-uniques"           Opt_SuppressUniques,
  flagSpec "suppress-var-kinds"         Opt_SuppressVarKinds]

-- | These @-f\<blah\>@ flags can all be reversed with @-fno-\<blah\>@
fFlags :: [FlagSpec GeneralFlag]
fFlags = [
-- See Note [Updating flag description in the User's Guide]
-- See Note [Supporting CLI completion]
-- Please keep the list of flags below sorted alphabetically
  flagGhciSpec "break-on-error"               Opt_BreakOnError,
  flagGhciSpec "break-on-exception"           Opt_BreakOnException,
  flagSpec "building-cabal-package"           Opt_BuildingCabalPackage,
  flagSpec "call-arity"                       Opt_CallArity,
  flagSpec "case-merge"                       Opt_CaseMerge,
  flagSpec "cmm-elim-common-blocks"           Opt_CmmElimCommonBlocks,
  flagSpec "cmm-sink"                         Opt_CmmSink,
  flagSpec "cse"                              Opt_CSE,
  flagSpec "defer-type-errors"                Opt_DeferTypeErrors,
  flagSpec "defer-typed-holes"                Opt_DeferTypedHoles,
  flagSpec "dicts-cheap"                      Opt_DictsCheap,
  flagSpec "dicts-strict"                     Opt_DictsStrict,
  flagSpec "dmd-tx-dict-sel"                  Opt_DmdTxDictSel,
  flagSpec "do-eta-reduction"                 Opt_DoEtaReduction,
  flagSpec "do-lambda-eta-expansion"          Opt_DoLambdaEtaExpansion,
  flagSpec "eager-blackholing"                Opt_EagerBlackHoling,
  flagSpec "embed-manifest"                   Opt_EmbedManifest,
  flagSpec "enable-rewrite-rules"             Opt_EnableRewriteRules,
  flagSpec "error-spans"                      Opt_ErrorSpans,
  flagSpec "excess-precision"                 Opt_ExcessPrecision,
  flagSpec "expose-all-unfoldings"            Opt_ExposeAllUnfoldings,
  flagSpec "flat-cache"                       Opt_FlatCache,
  flagSpec "float-in"                         Opt_FloatIn,
  flagSpec "force-recomp"                     Opt_ForceRecomp,
  flagSpec "full-laziness"                    Opt_FullLaziness,
  flagSpec "fun-to-thunk"                     Opt_FunToThunk,
  flagSpec "gen-manifest"                     Opt_GenManifest,
  flagSpec "ghci-history"                     Opt_GhciHistory,
  flagSpec "ghci-sandbox"                     Opt_GhciSandbox,
  flagSpec "helpful-errors"                   Opt_HelpfulErrors,
  flagSpec "hpc"                              Opt_Hpc,
  flagSpec "ignore-asserts"                   Opt_IgnoreAsserts,
  flagSpec "ignore-interface-pragmas"         Opt_IgnoreInterfacePragmas,
  flagGhciSpec "implicit-import-qualified"    Opt_ImplicitImportQualified,
  flagSpec "irrefutable-tuples"               Opt_IrrefutableTuples,
  flagSpec "kill-absence"                     Opt_KillAbsence,
  flagSpec "kill-one-shot"                    Opt_KillOneShot,
  flagSpec "late-dmd-anal"                    Opt_LateDmdAnal,
  flagSpec "liberate-case"                    Opt_LiberateCase,
  flagHiddenSpec "llvm-pass-vectors-in-regs"  Opt_LlvmPassVectorsInRegisters,
  flagHiddenSpec "llvm-tbaa"                  Opt_LlvmTBAA,
  flagSpec "loopification"                    Opt_Loopification,
  flagSpec "omit-interface-pragmas"           Opt_OmitInterfacePragmas,
  flagSpec "omit-yields"                      Opt_OmitYields,
  flagSpec "pedantic-bottoms"                 Opt_PedanticBottoms,
  flagSpec "pre-inlining"                     Opt_SimplPreInlining,
  flagGhciSpec "print-bind-contents"          Opt_PrintBindContents,
  flagGhciSpec "print-bind-result"            Opt_PrintBindResult,
  flagGhciSpec "print-evld-with-show"         Opt_PrintEvldWithShow,
  flagSpec "print-explicit-foralls"           Opt_PrintExplicitForalls,
  flagSpec "print-explicit-kinds"             Opt_PrintExplicitKinds,
  flagSpec "print-unicode-syntax"             Opt_PrintUnicodeSyntax,
  flagSpec "prof-cafs"                        Opt_AutoSccsOnIndividualCafs,
  flagSpec "prof-count-entries"               Opt_ProfCountEntries,
  flagSpec "regs-graph"                       Opt_RegsGraph,
  flagSpec "regs-iterative"                   Opt_RegsIterative,
  flagSpec' "rewrite-rules"                   Opt_EnableRewriteRules
    (useInstead "enable-rewrite-rules"),
  flagSpec "shared-implib"                    Opt_SharedImplib,
  flagSpec "simple-list-literals"             Opt_SimpleListLiterals,
  flagSpec "spec-constr"                      Opt_SpecConstr,
  flagSpec "specialise"                       Opt_Specialise,
  flagSpec "specialise-aggressively"          Opt_SpecialiseAggressively,
  flagSpec "cross-module-specialise"          Opt_CrossModuleSpecialise,
  flagSpec "static-argument-transformation"   Opt_StaticArgumentTransformation,
  flagSpec "strictness"                       Opt_Strictness,
  flagSpec "use-rpaths"                       Opt_RPath,
  flagSpec "write-interface"                  Opt_WriteInterface,
  flagSpec "unbox-small-strict-fields"        Opt_UnboxSmallStrictFields,
  flagSpec "unbox-strict-fields"              Opt_UnboxStrictFields,
  flagSpec "vectorisation-avoidance"          Opt_VectorisationAvoidance,
  flagSpec "vectorise"                        Opt_Vectorise
  ]

-- | These @-f\<blah\>@ flags can all be reversed with @-fno-\<blah\>@
fLangFlags :: [FlagSpec ExtensionFlag]
fLangFlags = [
-- See Note [Updating flag description in the User's Guide]
-- See Note [Supporting CLI completion]
  flagSpec' "th"                              Opt_TemplateHaskell
    (\on -> deprecatedForExtension "TemplateHaskell" on
         >> setTemplateHaskellLoc on),
  flagSpec' "fi"                              Opt_ForeignFunctionInterface
    (deprecatedForExtension "ForeignFunctionInterface"),
  flagSpec' "ffi"                             Opt_ForeignFunctionInterface
    (deprecatedForExtension "ForeignFunctionInterface"),
  flagSpec' "arrows"                          Opt_Arrows
    (deprecatedForExtension "Arrows"),
  flagSpec' "implicit-prelude"                Opt_ImplicitPrelude
    (deprecatedForExtension "ImplicitPrelude"),
  flagSpec' "bang-patterns"                   Opt_BangPatterns
    (deprecatedForExtension "BangPatterns"),
  flagSpec' "monomorphism-restriction"        Opt_MonomorphismRestriction
    (deprecatedForExtension "MonomorphismRestriction"),
  flagSpec' "mono-pat-binds"                  Opt_MonoPatBinds
    (deprecatedForExtension "MonoPatBinds"),
  flagSpec' "extended-default-rules"          Opt_ExtendedDefaultRules
    (deprecatedForExtension "ExtendedDefaultRules"),
  flagSpec' "implicit-params"                 Opt_ImplicitParams
    (deprecatedForExtension "ImplicitParams"),
  flagSpec' "scoped-type-variables"           Opt_ScopedTypeVariables
    (deprecatedForExtension "ScopedTypeVariables"),
  flagSpec' "parr"                            Opt_ParallelArrays
    (deprecatedForExtension "ParallelArrays"),
  flagSpec' "PArr"                            Opt_ParallelArrays
    (deprecatedForExtension "ParallelArrays"),
  flagSpec' "allow-overlapping-instances"     Opt_OverlappingInstances
    (deprecatedForExtension "OverlappingInstances"),
  flagSpec' "allow-undecidable-instances"     Opt_UndecidableInstances
    (deprecatedForExtension "UndecidableInstances"),
  flagSpec' "allow-incoherent-instances"      Opt_IncoherentInstances
    (deprecatedForExtension "IncoherentInstances")
  ]

supportedLanguages :: [String]
supportedLanguages = map flagSpecName languageFlags

supportedLanguageOverlays :: [String]
supportedLanguageOverlays = map flagSpecName safeHaskellFlags

supportedExtensions :: [String]
supportedExtensions
    = concatMap (\name -> [name, "No" ++ name]) (map flagSpecName xFlags)

supportedLanguagesAndExtensions :: [String]
supportedLanguagesAndExtensions =
    supportedLanguages ++ supportedLanguageOverlays ++ supportedExtensions

-- | These -X<blah> flags cannot be reversed with -XNo<blah>
languageFlags :: [FlagSpec Language]
languageFlags = [
  flagSpec "Haskell98"   Haskell98,
  flagSpec "Haskell2010" Haskell2010
  ]

-- | These -X<blah> flags cannot be reversed with -XNo<blah>
-- They are used to place hard requirements on what GHC Haskell language
-- features can be used.
safeHaskellFlags :: [FlagSpec SafeHaskellMode]
safeHaskellFlags = [mkF Sf_Unsafe, mkF Sf_Trustworthy, mkF Sf_Safe]
    where mkF flag = flagSpec (show flag) flag

-- | These -X<blah> flags can all be reversed with -XNo<blah>
xFlags :: [FlagSpec ExtensionFlag]
xFlags = [
-- See Note [Updating flag description in the User's Guide]
-- See Note [Supporting CLI completion]
-- Please keep the list of flags below sorted alphabetically
  flagSpec "AllowAmbiguousTypes"              Opt_AllowAmbiguousTypes,
  flagSpec "AlternativeLayoutRule"            Opt_AlternativeLayoutRule,
  flagSpec "AlternativeLayoutRuleTransitional"
                                          Opt_AlternativeLayoutRuleTransitional,
  flagSpec "Arrows"                           Opt_Arrows,
  flagSpec "AutoDeriveTypeable"               Opt_AutoDeriveTypeable,
  flagSpec "BangPatterns"                     Opt_BangPatterns,
  flagSpec "BinaryLiterals"                   Opt_BinaryLiterals,
  flagSpec "CApiFFI"                          Opt_CApiFFI,
  flagSpec "CPP"                              Opt_Cpp,
  flagSpec "ConstrainedClassMethods"          Opt_ConstrainedClassMethods,
  flagSpec "ConstraintKinds"                  Opt_ConstraintKinds,
  flagSpec "DataKinds"                        Opt_DataKinds,
  flagSpec' "DatatypeContexts"                Opt_DatatypeContexts
    (\ turn_on -> when turn_on $
         deprecate $ "It was widely considered a misfeature, " ++
                     "and has been removed from the Haskell language."),
  flagSpec "DefaultSignatures"                Opt_DefaultSignatures,
  flagSpec "DeriveAnyClass"                   Opt_DeriveAnyClass,
  flagSpec "DeriveDataTypeable"               Opt_DeriveDataTypeable,
  flagSpec "DeriveFoldable"                   Opt_DeriveFoldable,
  flagSpec "DeriveFunctor"                    Opt_DeriveFunctor,
  flagSpec "DeriveGeneric"                    Opt_DeriveGeneric,
  flagSpec "DeriveTraversable"                Opt_DeriveTraversable,
  flagSpec "DisambiguateRecordFields"         Opt_DisambiguateRecordFields,
  flagSpec "DoAndIfThenElse"                  Opt_DoAndIfThenElse,
  flagSpec' "DoRec"                           Opt_RecursiveDo
    (deprecatedForExtension "RecursiveDo"),
  flagSpec "EmptyCase"                        Opt_EmptyCase,
  flagSpec "EmptyDataDecls"                   Opt_EmptyDataDecls,
  flagSpec "ExistentialQuantification"        Opt_ExistentialQuantification,
  flagSpec "ExplicitForAll"                   Opt_ExplicitForAll,
  flagSpec "ExplicitNamespaces"               Opt_ExplicitNamespaces,
  flagSpec "ExtendedDefaultRules"             Opt_ExtendedDefaultRules,
  flagSpec "FlexibleContexts"                 Opt_FlexibleContexts,
  flagSpec "FlexibleInstances"                Opt_FlexibleInstances,
  flagSpec "ForeignFunctionInterface"         Opt_ForeignFunctionInterface,
  flagSpec "FunctionalDependencies"           Opt_FunctionalDependencies,
  flagSpec "GADTSyntax"                       Opt_GADTSyntax,
  flagSpec "GADTs"                            Opt_GADTs,
  flagSpec "GHCForeignImportPrim"             Opt_GHCForeignImportPrim,
  flagSpec' "GeneralizedNewtypeDeriving"      Opt_GeneralizedNewtypeDeriving
                                              setGenDeriving,
  flagSpec "ImplicitParams"                   Opt_ImplicitParams,
  flagSpec "ImplicitPrelude"                  Opt_ImplicitPrelude,
  flagSpec "ImpredicativeTypes"               Opt_ImpredicativeTypes,
  flagSpec' "IncoherentInstances"             Opt_IncoherentInstances
                                              setIncoherentInsts,
  flagSpec "InstanceSigs"                     Opt_InstanceSigs,
  flagSpec "InterruptibleFFI"                 Opt_InterruptibleFFI,
  flagSpec "JavaScriptFFI"                    Opt_JavaScriptFFI,
  flagSpec "KindSignatures"                   Opt_KindSignatures,
  flagSpec "LambdaCase"                       Opt_LambdaCase,
  flagSpec "LiberalTypeSynonyms"              Opt_LiberalTypeSynonyms,
  flagSpec "MagicHash"                        Opt_MagicHash,
  flagSpec "MonadComprehensions"              Opt_MonadComprehensions,
  flagSpec "MonoLocalBinds"                   Opt_MonoLocalBinds,
  flagSpec' "MonoPatBinds"                    Opt_MonoPatBinds
    (\ turn_on -> when turn_on $
         deprecate "Experimental feature now removed; has no effect"),
  flagSpec "MonomorphismRestriction"          Opt_MonomorphismRestriction,
  flagSpec "MultiParamTypeClasses"            Opt_MultiParamTypeClasses,
  flagSpec "MultiWayIf"                       Opt_MultiWayIf,
  flagSpec "NPlusKPatterns"                   Opt_NPlusKPatterns,
  flagSpec "NamedFieldPuns"                   Opt_RecordPuns,
  flagSpec "NamedWildCards"                   Opt_NamedWildCards,
  flagSpec "NegativeLiterals"                 Opt_NegativeLiterals,
  flagSpec "NondecreasingIndentation"         Opt_NondecreasingIndentation,
  flagSpec' "NullaryTypeClasses"              Opt_NullaryTypeClasses
    (deprecatedForExtension "MultiParamTypeClasses"),
  flagSpec "NumDecimals"                      Opt_NumDecimals,
  flagSpec' "OverlappingInstances"            Opt_OverlappingInstances
                                              setOverlappingInsts,
  flagSpec "OverloadedLists"                  Opt_OverloadedLists,
  flagSpec "OverloadedStrings"                Opt_OverloadedStrings,
  flagSpec "PackageImports"                   Opt_PackageImports,
  flagSpec "ParallelArrays"                   Opt_ParallelArrays,
  flagSpec "ParallelListComp"                 Opt_ParallelListComp,
  flagSpec "PartialTypeSignatures"            Opt_PartialTypeSignatures,
  flagSpec "PatternGuards"                    Opt_PatternGuards,
  flagSpec' "PatternSignatures"               Opt_ScopedTypeVariables
    (deprecatedForExtension "ScopedTypeVariables"),
  flagSpec "PatternSynonyms"                  Opt_PatternSynonyms,
  flagSpec "PolyKinds"                        Opt_PolyKinds,
  flagSpec "PolymorphicComponents"            Opt_RankNTypes,
  flagSpec "PostfixOperators"                 Opt_PostfixOperators,
  flagSpec "QuasiQuotes"                      Opt_QuasiQuotes,
  flagSpec "Rank2Types"                       Opt_RankNTypes,
  flagSpec "RankNTypes"                       Opt_RankNTypes,
  flagSpec "RebindableSyntax"                 Opt_RebindableSyntax,
  flagSpec' "RecordPuns"                      Opt_RecordPuns
    (deprecatedForExtension "NamedFieldPuns"),
  flagSpec "RecordWildCards"                  Opt_RecordWildCards,
  flagSpec "RecursiveDo"                      Opt_RecursiveDo,
  flagSpec "RelaxedLayout"                    Opt_RelaxedLayout,
  flagSpec' "RelaxedPolyRec"                  Opt_RelaxedPolyRec
    (\ turn_on -> unless turn_on $
         deprecate "You can't turn off RelaxedPolyRec any more"),
  flagSpec "RoleAnnotations"                  Opt_RoleAnnotations,
  flagSpec "ScopedTypeVariables"              Opt_ScopedTypeVariables,
  flagSpec "StandaloneDeriving"               Opt_StandaloneDeriving,
  flagSpec "StaticPointers"                   Opt_StaticPointers,
  flagSpec' "TemplateHaskell"                 Opt_TemplateHaskell
                                              setTemplateHaskellLoc,
  flagSpec "TraditionalRecordSyntax"          Opt_TraditionalRecordSyntax,
  flagSpec "TransformListComp"                Opt_TransformListComp,
  flagSpec "TupleSections"                    Opt_TupleSections,
  flagSpec "TypeFamilies"                     Opt_TypeFamilies,
  flagSpec "TypeOperators"                    Opt_TypeOperators,
  flagSpec "TypeSynonymInstances"             Opt_TypeSynonymInstances,
  flagSpec "UnboxedTuples"                    Opt_UnboxedTuples,
  flagSpec "UndecidableInstances"             Opt_UndecidableInstances,
  flagSpec "UnicodeSyntax"                    Opt_UnicodeSyntax,
  flagSpec "UnliftedFFITypes"                 Opt_UnliftedFFITypes,
  flagSpec "ViewPatterns"                     Opt_ViewPatterns
  ]

defaultFlags :: Settings -> [GeneralFlag]
defaultFlags settings
-- See Note [Updating flag description in the User's Guide]
  = [ Opt_AutoLinkPackages,
      Opt_EmbedManifest,
      Opt_FlatCache,
      Opt_GenManifest,
      Opt_GhciHistory,
      Opt_GhciSandbox,
      Opt_HelpfulErrors,
      Opt_OmitYields,
      Opt_PrintBindContents,
      Opt_ProfCountEntries,
      Opt_RPath,
      Opt_SharedImplib,
      Opt_SimplPreInlining
    ]

    ++ [f | (ns,f) <- optLevelFlags, 0 `elem` ns]
             -- The default -O0 options

    ++ default_PIC platform

    ++ (if pc_DYNAMIC_BY_DEFAULT (sPlatformConstants settings)
        then wayGeneralFlags platform WayDyn
        else [])

    where platform = sTargetPlatform settings

default_PIC :: Platform -> [GeneralFlag]
default_PIC platform =
  case (platformOS platform, platformArch platform) of
    (OSDarwin, ArchX86_64) -> [Opt_PIC]
    (OSOpenBSD, ArchX86_64) -> [Opt_PIC] -- Due to PIE support in
                                         -- OpenBSD since 5.3 release
                                         -- (1 May 2013) we need to
                                         -- always generate PIC. See
                                         -- #10597 for more
                                         -- information.
    _                      -> []

impliedGFlags :: [(GeneralFlag, TurnOnFlag, GeneralFlag)]
impliedGFlags = [(Opt_DeferTypeErrors, turnOn, Opt_DeferTypedHoles)]

impliedXFlags :: [(ExtensionFlag, TurnOnFlag, ExtensionFlag)]
impliedXFlags
-- See Note [Updating flag description in the User's Guide]
  = [ (Opt_RankNTypes,                turnOn, Opt_ExplicitForAll)
    , (Opt_ScopedTypeVariables,       turnOn, Opt_ExplicitForAll)
    , (Opt_LiberalTypeSynonyms,       turnOn, Opt_ExplicitForAll)
    , (Opt_ExistentialQuantification, turnOn, Opt_ExplicitForAll)
    , (Opt_FlexibleInstances,         turnOn, Opt_TypeSynonymInstances)
    , (Opt_FunctionalDependencies,    turnOn, Opt_MultiParamTypeClasses)
    , (Opt_MultiParamTypeClasses,     turnOn, Opt_ConstrainedClassMethods)  -- c.f. Trac #7854

    , (Opt_RebindableSyntax, turnOff, Opt_ImplicitPrelude)      -- NB: turn off!

    , (Opt_GADTs,            turnOn, Opt_GADTSyntax)
    , (Opt_GADTs,            turnOn, Opt_MonoLocalBinds)
    , (Opt_TypeFamilies,     turnOn, Opt_MonoLocalBinds)

    , (Opt_TypeFamilies,     turnOn, Opt_KindSignatures)  -- Type families use kind signatures
    , (Opt_PolyKinds,        turnOn, Opt_KindSignatures)  -- Ditto polymorphic kinds

    -- AutoDeriveTypeable is not very useful without DeriveDataTypeable
    , (Opt_AutoDeriveTypeable, turnOn, Opt_DeriveDataTypeable)

    -- We turn this on so that we can export associated type
    -- type synonyms in subordinates (e.g. MyClass(type AssocType))
    , (Opt_TypeFamilies,     turnOn, Opt_ExplicitNamespaces)
    , (Opt_TypeOperators, turnOn, Opt_ExplicitNamespaces)

    , (Opt_ImpredicativeTypes,  turnOn, Opt_RankNTypes)

        -- Record wild-cards implies field disambiguation
        -- Otherwise if you write (C {..}) you may well get
        -- stuff like " 'a' not in scope ", which is a bit silly
        -- if the compiler has just filled in field 'a' of constructor 'C'
    , (Opt_RecordWildCards,     turnOn, Opt_DisambiguateRecordFields)

    , (Opt_ParallelArrays, turnOn, Opt_ParallelListComp)

    , (Opt_JavaScriptFFI, turnOn, Opt_InterruptibleFFI)

    , (Opt_DeriveTraversable, turnOn, Opt_DeriveFunctor)
    , (Opt_DeriveTraversable, turnOn, Opt_DeriveFoldable)
  ]

-- Note [Documenting optimisation flags]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- If you change the list of flags enabled for particular optimisation levels
-- please remember to update the User's Guide. The relevant files are:
--
--  * docs/users_guide/flags.xml
--  * docs/users_guide/using.xml
--
-- The first contains the Flag Refrence section, which breifly lists all
-- available flags. The second contains a detailed description of the
-- flags. Both places should contain information whether a flag is implied by
-- -O0, -O or -O2.

optLevelFlags :: [([Int], GeneralFlag)]
optLevelFlags -- see Note [Documenting optimisation flags]
  = [ ([0,1,2], Opt_DoLambdaEtaExpansion)
    , ([0,1,2], Opt_DmdTxDictSel)
    , ([0,1,2], Opt_LlvmTBAA)
    , ([0,1,2], Opt_VectorisationAvoidance)
                -- This one is important for a tiresome reason:
                -- we want to make sure that the bindings for data
                -- constructors are eta-expanded.  This is probably
                -- a good thing anyway, but it seems fragile.

    , ([0],     Opt_IgnoreInterfacePragmas)
    , ([0],     Opt_OmitInterfacePragmas)

    , ([1,2],   Opt_CallArity)
    , ([1,2],   Opt_CaseMerge)
    , ([1,2],   Opt_CmmElimCommonBlocks)
    , ([1,2],   Opt_CmmSink)
    , ([1,2],   Opt_CSE)
    , ([1,2],   Opt_DoEtaReduction)
    , ([1,2],   Opt_EnableRewriteRules)  -- Off for -O0; see Note [Scoping for Builtin rules]
                                         --              in PrelRules
    , ([1,2],   Opt_FloatIn)
    , ([1,2],   Opt_FullLaziness)
    , ([1,2],   Opt_IgnoreAsserts)
    , ([1,2],   Opt_Loopification)
    , ([1,2],   Opt_Specialise)
    , ([1,2],   Opt_CrossModuleSpecialise)
    , ([1,2],   Opt_Strictness)
    , ([1,2],   Opt_UnboxSmallStrictFields)

    , ([2],     Opt_LiberateCase)
    , ([2],     Opt_SpecConstr)
--  , ([2],     Opt_RegsGraph)
--   RegsGraph suffers performance regression. See #7679
--  , ([2],     Opt_StaticArgumentTransformation)
--   Static Argument Transformation needs investigation. See #9374
    ]

-- -----------------------------------------------------------------------------
-- Standard sets of warning options

-- Note [Documenting warning flags]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
--
-- If you change the list of warning enabled by default
-- please remember to update the User's Guide. The relevant file is:
--
--  * docs/users_guide/using.xml

standardWarnings :: [WarningFlag]
standardWarnings -- see Note [Documenting warning flags]
    = [ Opt_WarnOverlappingPatterns,
        Opt_WarnWarningsDeprecations,
        Opt_WarnDeprecatedFlags,
        Opt_WarnDeferredTypeErrors,
        Opt_WarnTypedHoles,
        Opt_WarnPartialTypeSignatures,
        Opt_WarnUnrecognisedPragmas,
        Opt_WarnPointlessPragmas,
        Opt_WarnRedundantConstraints,
        Opt_WarnDuplicateExports,
        Opt_WarnOverflowedLiterals,
        Opt_WarnEmptyEnumerations,
        Opt_WarnMissingFields,
        Opt_WarnMissingMethods,
        Opt_WarnWrongDoBind,
        Opt_WarnUnsupportedCallingConventions,
        Opt_WarnDodgyForeignImports,
        Opt_WarnInlineRuleShadowing,
        Opt_WarnAlternativeLayoutRuleTransitional,
        Opt_WarnUnsupportedLlvmVersion,
        Opt_WarnContextQuantification,
        Opt_WarnTabs
      ]

minusWOpts :: [WarningFlag]
-- Things you get with -W
minusWOpts
    = standardWarnings ++
      [ Opt_WarnUnusedTopBinds,
        Opt_WarnUnusedLocalBinds,
        Opt_WarnUnusedPatternBinds,
        Opt_WarnUnusedMatches,
        Opt_WarnUnusedImports,
        Opt_WarnIncompletePatterns,
        Opt_WarnDodgyExports,
        Opt_WarnDodgyImports
      ]

minusWallOpts :: [WarningFlag]
-- Things you get with -Wall
minusWallOpts
    = minusWOpts ++
      [ Opt_WarnTypeDefaults,
        Opt_WarnNameShadowing,
        Opt_WarnMissingSigs,
        Opt_WarnHiShadows,
        Opt_WarnOrphans,
        Opt_WarnUnusedDoBind,
        Opt_WarnTrustworthySafe,
        Opt_WarnUntickedPromotedConstructors
      ]

enableUnusedBinds :: DynP ()
enableUnusedBinds = mapM_ setWarningFlag unusedBindsFlags

disableUnusedBinds :: DynP ()
disableUnusedBinds = mapM_ unSetWarningFlag unusedBindsFlags

-- Things you get with -fwarn-unused-binds
unusedBindsFlags :: [WarningFlag]
unusedBindsFlags = [ Opt_WarnUnusedTopBinds
                   , Opt_WarnUnusedLocalBinds
                   , Opt_WarnUnusedPatternBinds
                   ]

enableGlasgowExts :: DynP ()
enableGlasgowExts = do setGeneralFlag Opt_PrintExplicitForalls
                       mapM_ setExtensionFlag glasgowExtsFlags

disableGlasgowExts :: DynP ()
disableGlasgowExts = do unSetGeneralFlag Opt_PrintExplicitForalls
                        mapM_ unSetExtensionFlag glasgowExtsFlags

glasgowExtsFlags :: [ExtensionFlag]
glasgowExtsFlags = [
             Opt_ConstrainedClassMethods
           , Opt_DeriveDataTypeable
           , Opt_DeriveFoldable
           , Opt_DeriveFunctor
           , Opt_DeriveGeneric
           , Opt_DeriveTraversable
           , Opt_EmptyDataDecls
           , Opt_ExistentialQuantification
           , Opt_ExplicitNamespaces
           , Opt_FlexibleContexts
           , Opt_FlexibleInstances
           , Opt_ForeignFunctionInterface
           , Opt_FunctionalDependencies
           , Opt_GeneralizedNewtypeDeriving
           , Opt_ImplicitParams
           , Opt_KindSignatures
           , Opt_LiberalTypeSynonyms
           , Opt_MagicHash
           , Opt_MultiParamTypeClasses
           , Opt_ParallelListComp
           , Opt_PatternGuards
           , Opt_PostfixOperators
           , Opt_RankNTypes
           , Opt_RecursiveDo
           , Opt_ScopedTypeVariables
           , Opt_StandaloneDeriving
           , Opt_TypeOperators
           , Opt_TypeSynonymInstances
           , Opt_UnboxedTuples
           , Opt_UnicodeSyntax
           , Opt_UnliftedFFITypes ]

#ifdef GHCI
-- Consult the RTS to find whether GHC itself has been built profiled
-- If so, you can't use Template Haskell
foreign import ccall unsafe "rts_isProfiled" rtsIsProfiledIO :: IO CInt

rtsIsProfiled :: Bool
rtsIsProfiled = unsafeDupablePerformIO rtsIsProfiledIO /= 0
#endif

#ifdef GHCI
-- Consult the RTS to find whether GHC itself has been built with
-- dynamic linking.  This can't be statically known at compile-time,
-- because we build both the static and dynamic versions together with
-- -dynamic-too.
foreign import ccall unsafe "rts_isDynamic" rtsIsDynamicIO :: IO CInt

dynamicGhc :: Bool
dynamicGhc = unsafeDupablePerformIO rtsIsDynamicIO /= 0
#else
dynamicGhc :: Bool
dynamicGhc = False
#endif

setWarnSafe :: Bool -> DynP ()
setWarnSafe True  = getCurLoc >>= \l -> upd (\d -> d { warnSafeOnLoc = l })
setWarnSafe False = return ()

setWarnUnsafe :: Bool -> DynP ()
setWarnUnsafe True  = getCurLoc >>= \l -> upd (\d -> d { warnUnsafeOnLoc = l })
setWarnUnsafe False = return ()

setPackageTrust :: DynP ()
setPackageTrust = do
    setGeneralFlag Opt_PackageTrust
    l <- getCurLoc
    upd $ \d -> d { pkgTrustOnLoc = l }

setGenDeriving :: TurnOnFlag -> DynP ()
setGenDeriving True  = getCurLoc >>= \l -> upd (\d -> d { newDerivOnLoc = l })
setGenDeriving False = return ()

setOverlappingInsts :: TurnOnFlag -> DynP ()
setOverlappingInsts False = return ()
setOverlappingInsts True = do
  l <- getCurLoc
  upd (\d -> d { overlapInstLoc = l })
  deprecate "instead use per-instance pragmas OVERLAPPING/OVERLAPPABLE/OVERLAPS"

setIncoherentInsts :: TurnOnFlag -> DynP ()
setIncoherentInsts False = return ()
setIncoherentInsts True = do
  l <- getCurLoc
  upd (\d -> d { incoherentOnLoc = l })

setTemplateHaskellLoc :: TurnOnFlag -> DynP ()
setTemplateHaskellLoc _
  = getCurLoc >>= \l -> upd (\d -> d { thOnLoc = l })

{- **********************************************************************
%*                                                                      *
                DynFlags constructors
%*                                                                      *
%********************************************************************* -}

type DynP = EwM (CmdLineP DynFlags)

upd :: (DynFlags -> DynFlags) -> DynP ()
upd f = liftEwM (do dflags <- getCmdLineState
                    putCmdLineState $! f dflags)

updM :: (DynFlags -> DynP DynFlags) -> DynP ()
updM f = do dflags <- liftEwM getCmdLineState
            dflags' <- f dflags
            liftEwM $ putCmdLineState $! dflags'

--------------- Constructor functions for OptKind -----------------
noArg :: (DynFlags -> DynFlags) -> OptKind (CmdLineP DynFlags)
noArg fn = NoArg (upd fn)

noArgM :: (DynFlags -> DynP DynFlags) -> OptKind (CmdLineP DynFlags)
noArgM fn = NoArg (updM fn)

hasArg :: (String -> DynFlags -> DynFlags) -> OptKind (CmdLineP DynFlags)
hasArg fn = HasArg (upd . fn)

sepArg :: (String -> DynFlags -> DynFlags) -> OptKind (CmdLineP DynFlags)
sepArg fn = SepArg (upd . fn)

intSuffix :: (Int -> DynFlags -> DynFlags) -> OptKind (CmdLineP DynFlags)
intSuffix fn = IntSuffix (\n -> upd (fn n))

intSuffixM :: (Int -> DynFlags -> DynP DynFlags) -> OptKind (CmdLineP DynFlags)
intSuffixM fn = IntSuffix (\n -> updM (fn n))

floatSuffix :: (Float -> DynFlags -> DynFlags) -> OptKind (CmdLineP DynFlags)
floatSuffix fn = FloatSuffix (\n -> upd (fn n))

optIntSuffixM :: (Maybe Int -> DynFlags -> DynP DynFlags)
              -> OptKind (CmdLineP DynFlags)
optIntSuffixM fn = OptIntSuffix (\mi -> updM (fn mi))

setDumpFlag :: DumpFlag -> OptKind (CmdLineP DynFlags)
setDumpFlag dump_flag = NoArg (setDumpFlag' dump_flag)

--------------------------
addWay :: Way -> DynP ()
addWay w = upd (addWay' w)

addWay' :: Way -> DynFlags -> DynFlags
addWay' w dflags0 = let platform = targetPlatform dflags0
                        dflags1 = dflags0 { ways = w : ways dflags0 }
                        dflags2 = wayExtras platform w dflags1
                        dflags3 = foldr setGeneralFlag' dflags2
                                        (wayGeneralFlags platform w)
                        dflags4 = foldr unSetGeneralFlag' dflags3
                                        (wayUnsetGeneralFlags platform w)
                    in dflags4

removeWayDyn :: DynP ()
removeWayDyn = upd (\dfs -> dfs { ways = filter (WayDyn /=) (ways dfs) })

--------------------------
setGeneralFlag, unSetGeneralFlag :: GeneralFlag -> DynP ()
setGeneralFlag   f = upd (setGeneralFlag' f)
unSetGeneralFlag f = upd (unSetGeneralFlag' f)

setGeneralFlag' :: GeneralFlag -> DynFlags -> DynFlags
setGeneralFlag' f dflags = foldr ($) (gopt_set dflags f) deps
  where
    deps = [ if turn_on then setGeneralFlag'   d
                        else unSetGeneralFlag' d
           | (f', turn_on, d) <- impliedGFlags, f' == f ]
        -- When you set f, set the ones it implies
        -- NB: use setGeneralFlag recursively, in case the implied flags
        --     implies further flags

unSetGeneralFlag' :: GeneralFlag -> DynFlags -> DynFlags
unSetGeneralFlag' f dflags = gopt_unset dflags f
   -- When you un-set f, however, we don't un-set the things it implies

--------------------------
setWarningFlag, unSetWarningFlag :: WarningFlag -> DynP ()
setWarningFlag   f = upd (\dfs -> wopt_set dfs f)
unSetWarningFlag f = upd (\dfs -> wopt_unset dfs f)

--------------------------
setExtensionFlag, unSetExtensionFlag :: ExtensionFlag -> DynP ()
setExtensionFlag f = upd (setExtensionFlag' f)
unSetExtensionFlag f = upd (unSetExtensionFlag' f)

setExtensionFlag', unSetExtensionFlag' :: ExtensionFlag -> DynFlags -> DynFlags
setExtensionFlag' f dflags = foldr ($) (xopt_set dflags f) deps
  where
    deps = [ if turn_on then setExtensionFlag'   d
                        else unSetExtensionFlag' d
           | (f', turn_on, d) <- impliedXFlags, f' == f ]
        -- When you set f, set the ones it implies
        -- NB: use setExtensionFlag recursively, in case the implied flags
        --     implies further flags

unSetExtensionFlag' f dflags = xopt_unset dflags f
   -- When you un-set f, however, we don't un-set the things it implies
   --      (except for -fno-glasgow-exts, which is treated specially)

--------------------------
alterSettings :: (Settings -> Settings) -> DynFlags -> DynFlags
alterSettings f dflags = dflags { settings = f (settings dflags) }

--------------------------
setDumpFlag' :: DumpFlag -> DynP ()
setDumpFlag' dump_flag
  = do upd (\dfs -> dopt_set dfs dump_flag)
       when want_recomp forceRecompile
    where -- Certain dumpy-things are really interested in what's going
          -- on during recompilation checking, so in those cases we
          -- don't want to turn it off.
          want_recomp = dump_flag `notElem` [Opt_D_dump_if_trace,
                                             Opt_D_dump_hi_diffs]

forceRecompile :: DynP ()
-- Whenver we -ddump, force recompilation (by switching off the
-- recompilation checker), else you don't see the dump! However,
-- don't switch it off in --make mode, else *everything* gets
-- recompiled which probably isn't what you want
forceRecompile = do dfs <- liftEwM getCmdLineState
                    when (force_recomp dfs) (setGeneralFlag Opt_ForceRecomp)
        where
          force_recomp dfs = isOneShot (ghcMode dfs)


setVerboseCore2Core :: DynP ()
setVerboseCore2Core = setDumpFlag' Opt_D_verbose_core2core

setVerbosity :: Maybe Int -> DynP ()
setVerbosity mb_n = upd (\dfs -> dfs{ verbosity = mb_n `orElse` 3 })

addCmdlineHCInclude :: String -> DynP ()
addCmdlineHCInclude a = upd (\s -> s{cmdlineHcIncludes =  a : cmdlineHcIncludes s})

data PkgConfRef
  = GlobalPkgConf
  | UserPkgConf
  | PkgConfFile FilePath

addPkgConfRef :: PkgConfRef -> DynP ()
addPkgConfRef p = upd $ \s -> s { extraPkgConfs = (p:) . extraPkgConfs s }

removeUserPkgConf :: DynP ()
removeUserPkgConf = upd $ \s -> s { extraPkgConfs = filter isNotUser . extraPkgConfs s }
  where
    isNotUser UserPkgConf = False
    isNotUser _ = True

removeGlobalPkgConf :: DynP ()
removeGlobalPkgConf = upd $ \s -> s { extraPkgConfs = filter isNotGlobal . extraPkgConfs s }
  where
    isNotGlobal GlobalPkgConf = False
    isNotGlobal _ = True

clearPkgConf :: DynP ()
clearPkgConf = upd $ \s -> s { extraPkgConfs = const [] }

parseModuleName :: ReadP ModuleName
parseModuleName = fmap mkModuleName
                $ munch1 (\c -> isAlphaNum c || c `elem` ".")

parsePackageFlag :: (String -> PackageArg) -- type of argument
                 -> String                 -- string to parse
                 -> PackageFlag
parsePackageFlag constr str = case filter ((=="").snd) (readP_to_S parse str) of
    [(r, "")] -> r
    _ -> throwGhcException $ CmdLineError ("Can't parse package flag: " ++ str)
  where parse = do
            pkg <- tok $ munch1 (\c -> isAlphaNum c || c `elem` ":-_.")
            ( do _ <- tok $ string "with"
                 fmap (ExposePackage (constr pkg) . ModRenaming True) parseRns
             <++ fmap (ExposePackage (constr pkg) . ModRenaming False) parseRns
             <++ return (ExposePackage (constr pkg) (ModRenaming True [])))
        parseRns = do _ <- tok $ R.char '('
                      rns <- tok $ sepBy parseItem (tok $ R.char ',')
                      _ <- tok $ R.char ')'
                      return rns
        parseItem = do
            orig <- tok $ parseModuleName
            (do _ <- tok $ string "as"
                new <- tok $ parseModuleName
                return (orig, new)
              +++
             return (orig, orig))
        tok m = m >>= \x -> skipSpaces >> return x

exposePackage, exposePackageId, exposePackageKey, hidePackage, ignorePackage,
        trustPackage, distrustPackage :: String -> DynP ()
exposePackage p = upd (exposePackage' p)
exposePackageId p =
  upd (\s -> s{ packageFlags =
    parsePackageFlag PackageIdArg p : packageFlags s })
exposePackageKey p =
  upd (\s -> s{ packageFlags =
    parsePackageFlag PackageKeyArg p : packageFlags s })
hidePackage p =
  upd (\s -> s{ packageFlags = HidePackage p : packageFlags s })
ignorePackage p =
  upd (\s -> s{ packageFlags = IgnorePackage p : packageFlags s })
trustPackage p = exposePackage p >> -- both trust and distrust also expose a package
  upd (\s -> s{ packageFlags = TrustPackage p : packageFlags s })
distrustPackage p = exposePackage p >>
  upd (\s -> s{ packageFlags = DistrustPackage p : packageFlags s })

exposePackage' :: String -> DynFlags -> DynFlags
exposePackage' p dflags
    = dflags { packageFlags =
            parsePackageFlag PackageArg p : packageFlags dflags }

setPackageKey :: String -> DynFlags -> DynFlags
setPackageKey p s =  s{ thisPackage = stringToPackageKey p }

-- -----------------------------------------------------------------------------
-- | Find the package environment (if one exists)
--
-- We interpret the package environment as a set of package flags; to be
-- specific, if we find a package environment
--
-- > id1
-- > id2
-- > ..
-- > idn
--
-- we interpret this as
--
-- > [ -hide-all-packages
-- > , -package-id id1
-- > , -package-id id2
-- > , ..
-- > , -package-id idn
-- > ]
interpretPackageEnv :: DynFlags -> IO DynFlags
interpretPackageEnv dflags = do
    mPkgEnv <- runMaybeT $ msum $ [
                   getCmdLineArg >>= \env -> msum [
                       loadEnvFile  env
                     , loadEnvName  env
                     , cmdLineError env
                     ]
                 , getEnvVar >>= \env -> msum [
                       loadEnvFile env
                     , loadEnvName env
                     , envError    env
                     ]
                 , loadEnvFile localEnvFile
                 , loadEnvName defaultEnvName
                 ]
    case mPkgEnv of
      Nothing ->
        -- No environment found. Leave DynFlags unchanged.
        return dflags
      Just ids -> do
        let setFlags :: DynP ()
            setFlags = do
              setGeneralFlag Opt_HideAllPackages
              mapM_ exposePackageId (lines ids)

            (_, dflags') = runCmdLine (runEwM setFlags) dflags

        return dflags'
  where
    -- Loading environments (by name or by location)

    namedEnvPath :: String -> MaybeT IO FilePath
    namedEnvPath name = do
     appdir <- liftMaybeT $ versionedAppDir dflags
     return $ appdir </> "environments" </> name

    loadEnvName :: String -> MaybeT IO String
    loadEnvName name = loadEnvFile =<< namedEnvPath name

    loadEnvFile :: String -> MaybeT IO String
    loadEnvFile path = do
      guard =<< liftMaybeT (doesFileExist path)
      liftMaybeT $ readFile path

    -- Various ways to define which environment to use

    getCmdLineArg :: MaybeT IO String
    getCmdLineArg = MaybeT $ return $ packageEnv dflags

    getEnvVar :: MaybeT IO String
    getEnvVar = do
      mvar <- liftMaybeT $ try $ getEnv "GHC_ENVIRONMENT"
      case mvar of
        Right var -> return var
        Left err  -> if isDoesNotExistError err then mzero
                                                else liftMaybeT $ throwIO err

    defaultEnvName :: String
    defaultEnvName = "default"

    localEnvFile :: FilePath
    localEnvFile = "./.ghc.environment"

    -- Error reporting

    cmdLineError :: String -> MaybeT IO a
    cmdLineError env = liftMaybeT . throwGhcExceptionIO . CmdLineError $
      "Package environment " ++ show env ++ " not found"

    envError :: String -> MaybeT IO a
    envError env = liftMaybeT . throwGhcExceptionIO . CmdLineError $
         "Package environment "
      ++ show env
      ++ " (specified in GHC_ENVIRIONMENT) not found"


-- If we're linking a binary, then only targets that produce object
-- code are allowed (requests for other target types are ignored).
setTarget :: HscTarget -> DynP ()
setTarget l = setTargetWithPlatform (const l)

setTargetWithPlatform :: (Platform -> HscTarget) -> DynP ()
setTargetWithPlatform f = upd set
  where
   set dfs = let l = f (targetPlatform dfs)
             in if ghcLink dfs /= LinkBinary || isObjectTarget l
                then dfs{ hscTarget = l }
                else dfs

-- Changes the target only if we're compiling object code.  This is
-- used by -fasm and -fllvm, which switch from one to the other, but
-- not from bytecode to object-code.  The idea is that -fasm/-fllvm
-- can be safely used in an OPTIONS_GHC pragma.
setObjTarget :: HscTarget -> DynP ()
setObjTarget l = updM set
  where
   set dflags
     | isObjectTarget (hscTarget dflags)
       = return $ dflags { hscTarget = l }
     | otherwise = return dflags

setOptLevel :: Int -> DynFlags -> DynP DynFlags
setOptLevel n dflags = return (updOptLevel n dflags)

checkOptLevel :: Int -> DynFlags -> Either String DynFlags
checkOptLevel n dflags
   | hscTarget dflags == HscInterpreted && n > 0
     = Left "-O conflicts with --interactive; -O ignored."
   | otherwise
     = Right dflags

-- -Odph is equivalent to
--
--    -O2                               optimise as much as possible
--    -fmax-simplifier-iterations20     this is necessary sometimes
--    -fsimplifier-phases=3             we use an additional simplifier phase for fusion
--
setDPHOpt :: DynFlags -> DynP DynFlags
setDPHOpt dflags = setOptLevel 2 (dflags { maxSimplIterations  = 20
                                         , simplPhases         = 3
                                         })

setMainIs :: String -> DynP ()
setMainIs arg
  | not (null main_fn) && isLower (head main_fn)
     -- The arg looked like "Foo.Bar.baz"
  = upd $ \d -> d{ mainFunIs = Just main_fn,
                   mainModIs = mkModule mainPackageKey (mkModuleName main_mod) }

  | isUpper (head arg)  -- The arg looked like "Foo" or "Foo.Bar"
  = upd $ \d -> d{ mainModIs = mkModule mainPackageKey (mkModuleName arg) }

  | otherwise                   -- The arg looked like "baz"
  = upd $ \d -> d{ mainFunIs = Just arg }
  where
    (main_mod, main_fn) = splitLongestPrefix arg (== '.')

addLdInputs :: Option -> DynFlags -> DynFlags
addLdInputs p dflags = dflags{ldInputs = ldInputs dflags ++ [p]}

-----------------------------------------------------------------------------
-- Paths & Libraries

addImportPath, addLibraryPath, addIncludePath, addFrameworkPath :: FilePath -> DynP ()

-- -i on its own deletes the import paths
addImportPath "" = upd (\s -> s{importPaths = []})
addImportPath p  = upd (\s -> s{importPaths = importPaths s ++ splitPathList p})

addLibraryPath p =
  upd (\s -> s{libraryPaths = libraryPaths s ++ splitPathList p})

addIncludePath p =
  upd (\s -> s{includePaths = includePaths s ++ splitPathList p})

addFrameworkPath p =
  upd (\s -> s{frameworkPaths = frameworkPaths s ++ splitPathList p})

#ifndef mingw32_TARGET_OS
split_marker :: Char
split_marker = ':'   -- not configurable (ToDo)
#endif

splitPathList :: String -> [String]
splitPathList s = filter notNull (splitUp s)
                -- empty paths are ignored: there might be a trailing
                -- ':' in the initial list, for example.  Empty paths can
                -- cause confusion when they are translated into -I options
                -- for passing to gcc.
  where
#ifndef mingw32_TARGET_OS
    splitUp xs = split split_marker xs
#else
     -- Windows: 'hybrid' support for DOS-style paths in directory lists.
     --
     -- That is, if "foo:bar:baz" is used, this interpreted as
     -- consisting of three entries, 'foo', 'bar', 'baz'.
     -- However, with "c:/foo:c:\\foo;x:/bar", this is interpreted
     -- as 3 elts, "c:/foo", "c:\\foo", "x:/bar"
     --
     -- Notice that no attempt is made to fully replace the 'standard'
     -- split marker ':' with the Windows / DOS one, ';'. The reason being
     -- that this will cause too much breakage for users & ':' will
     -- work fine even with DOS paths, if you're not insisting on being silly.
     -- So, use either.
    splitUp []             = []
    splitUp (x:':':div:xs) | div `elem` dir_markers
                           = ((x:':':div:p): splitUp rs)
                           where
                              (p,rs) = findNextPath xs
          -- we used to check for existence of the path here, but that
          -- required the IO monad to be threaded through the command-line
          -- parser which is quite inconvenient.  The
    splitUp xs = cons p (splitUp rs)
               where
                 (p,rs) = findNextPath xs

                 cons "" xs = xs
                 cons x  xs = x:xs

    -- will be called either when we've consumed nought or the
    -- "<Drive>:/" part of a DOS path, so splitting is just a Q of
    -- finding the next split marker.
    findNextPath xs =
        case break (`elem` split_markers) xs of
           (p, _:ds) -> (p, ds)
           (p, xs)   -> (p, xs)

    split_markers :: [Char]
    split_markers = [':', ';']

    dir_markers :: [Char]
    dir_markers = ['/', '\\']
#endif

-- -----------------------------------------------------------------------------
-- tmpDir, where we store temporary files.

setTmpDir :: FilePath -> DynFlags -> DynFlags
setTmpDir dir = alterSettings (\s -> s { sTmpDir = normalise dir })
  -- we used to fix /cygdrive/c/.. on Windows, but this doesn't
  -- seem necessary now --SDM 7/2/2008

-----------------------------------------------------------------------------
-- RTS opts

setRtsOpts :: String -> DynP ()
setRtsOpts arg  = upd $ \ d -> d {rtsOpts = Just arg}

setRtsOptsEnabled :: RtsOptsEnabled -> DynP ()
setRtsOptsEnabled arg  = upd $ \ d -> d {rtsOptsEnabled = arg}

-----------------------------------------------------------------------------
-- Hpc stuff

setOptHpcDir :: String -> DynP ()
setOptHpcDir arg  = upd $ \ d -> d{hpcDir = arg}

-----------------------------------------------------------------------------
-- Via-C compilation stuff

-- There are some options that we need to pass to gcc when compiling
-- Haskell code via C, but are only supported by recent versions of
-- gcc.  The configure script decides which of these options we need,
-- and puts them in the "settings" file in $topdir. The advantage of
-- having these in a separate file is that the file can be created at
-- install-time depending on the available gcc version, and even
-- re-generated later if gcc is upgraded.
--
-- The options below are not dependent on the version of gcc, only the
-- platform.

picCCOpts :: DynFlags -> [String]
picCCOpts dflags
    = case platformOS (targetPlatform dflags) of
      OSDarwin
          -- Apple prefers to do things the other way round.
          -- PIC is on by default.
          -- -mdynamic-no-pic:
          --     Turn off PIC code generation.
          -- -fno-common:
          --     Don't generate "common" symbols - these are unwanted
          --     in dynamic libraries.

       | gopt Opt_PIC dflags -> ["-fno-common", "-U__PIC__", "-D__PIC__"]
       | otherwise           -> ["-mdynamic-no-pic"]
      OSMinGW32 -- no -fPIC for Windows
       | gopt Opt_PIC dflags -> ["-U__PIC__", "-D__PIC__"]
       | otherwise           -> []
      _
      -- we need -fPIC for C files when we are compiling with -dynamic,
      -- otherwise things like stub.c files don't get compiled
      -- correctly.  They need to reference data in the Haskell
      -- objects, but can't without -fPIC.  See
      -- http://ghc.haskell.org/trac/ghc/wiki/Commentary/PositionIndependentCode
       | gopt Opt_PIC dflags || not (gopt Opt_Static dflags) ->
          ["-fPIC", "-U__PIC__", "-D__PIC__"]
       | otherwise                             -> []

picPOpts :: DynFlags -> [String]
picPOpts dflags
 | gopt Opt_PIC dflags = ["-U__PIC__", "-D__PIC__"]
 | otherwise           = []

-- -----------------------------------------------------------------------------
-- Splitting

can_split :: Bool
can_split = cSupportsSplitObjs == "YES"

-- -----------------------------------------------------------------------------
-- Compiler Info

compilerInfo :: DynFlags -> [(String, String)]
compilerInfo dflags
    = -- We always make "Project name" be first to keep parsing in
      -- other languages simple, i.e. when looking for other fields,
      -- you don't have to worry whether there is a leading '[' or not
      ("Project name",                 cProjectName)
      -- Next come the settings, so anything else can be overridden
      -- in the settings file (as "lookup" uses the first match for the
      -- key)
    : rawSettings dflags
   ++ [("Project version",             projectVersion dflags),
       ("Project Git commit id",       cProjectGitCommitId),
       ("Booter version",              cBooterVersion),
       ("Stage",                       cStage),
       ("Build platform",              cBuildPlatformString),
       ("Host platform",               cHostPlatformString),
       ("Target platform",             cTargetPlatformString),
       ("Have interpreter",            cGhcWithInterpreter),
       ("Object splitting supported",  cSupportsSplitObjs),
       ("Have native code generator",  cGhcWithNativeCodeGen),
       ("Support SMP",                 cGhcWithSMP),
       ("Tables next to code",         cGhcEnableTablesNextToCode),
       ("RTS ways",                    cGhcRTSWays),
       ("Support dynamic-too",         if isWindows then "NO" else "YES"),
       ("Support parallel --make",     "YES"),
       ("Support reexported-modules",  "YES"),
       ("Support thinning and renaming package flags", "YES"),
       ("Uses package keys",           "YES"),
       ("Dynamic by default",          if dYNAMIC_BY_DEFAULT dflags
                                       then "YES" else "NO"),
       ("GHC Dynamic",                 if dynamicGhc
                                       then "YES" else "NO"),
       ("Leading underscore",          cLeadingUnderscore),
       ("Debug on",                    show debugIsOn),
       ("LibDir",                      topDir dflags),
       ("Global Package DB",           systemPackageConfig dflags)
      ]
  where
    isWindows = platformOS (targetPlatform dflags) == OSMinGW32

#include "../includes/dist-derivedconstants/header/GHCConstantsHaskellWrappers.hs"

bLOCK_SIZE_W :: DynFlags -> Int
bLOCK_SIZE_W dflags = bLOCK_SIZE dflags `quot` wORD_SIZE dflags

wORD_SIZE_IN_BITS :: DynFlags -> Int
wORD_SIZE_IN_BITS dflags = wORD_SIZE dflags * 8

tAG_MASK :: DynFlags -> Int
tAG_MASK dflags = (1 `shiftL` tAG_BITS dflags) - 1

mAX_PTR_TAG :: DynFlags -> Int
mAX_PTR_TAG = tAG_MASK

-- Might be worth caching these in targetPlatform?
tARGET_MIN_INT, tARGET_MAX_INT, tARGET_MAX_WORD :: DynFlags -> Integer
tARGET_MIN_INT dflags
    = case platformWordSize (targetPlatform dflags) of
      4 -> toInteger (minBound :: Int32)
      8 -> toInteger (minBound :: Int64)
      w -> panic ("tARGET_MIN_INT: Unknown platformWordSize: " ++ show w)
tARGET_MAX_INT dflags
    = case platformWordSize (targetPlatform dflags) of
      4 -> toInteger (maxBound :: Int32)
      8 -> toInteger (maxBound :: Int64)
      w -> panic ("tARGET_MAX_INT: Unknown platformWordSize: " ++ show w)
tARGET_MAX_WORD dflags
    = case platformWordSize (targetPlatform dflags) of
      4 -> toInteger (maxBound :: Word32)
      8 -> toInteger (maxBound :: Word64)
      w -> panic ("tARGET_MAX_WORD: Unknown platformWordSize: " ++ show w)

-- Whenever makeDynFlagsConsistent does anything, it starts over, to
-- ensure that a later change doesn't invalidate an earlier check.
-- Be careful not to introduce potential loops!
makeDynFlagsConsistent :: DynFlags -> (DynFlags, [Located String])
makeDynFlagsConsistent dflags
 -- Disable -dynamic-too on Windows (#8228, #7134, #5987)
 | os == OSMinGW32 && gopt Opt_BuildDynamicToo dflags
    = let dflags' = gopt_unset dflags Opt_BuildDynamicToo
          warn    = "-dynamic-too is not supported on Windows"
      in loop dflags' warn
 | hscTarget dflags == HscC &&
   not (platformUnregisterised (targetPlatform dflags))
    = if cGhcWithNativeCodeGen == "YES"
      then let dflags' = dflags { hscTarget = HscAsm }
               warn = "Compiler not unregisterised, so using native code generator rather than compiling via C"
           in loop dflags' warn
      else let dflags' = dflags { hscTarget = HscLlvm }
               warn = "Compiler not unregisterised, so using LLVM rather than compiling via C"
           in loop dflags' warn
 | hscTarget dflags == HscAsm &&
   platformUnregisterised (targetPlatform dflags)
    = loop (dflags { hscTarget = HscC })
           "Compiler unregisterised, so compiling via C"
 | hscTarget dflags == HscAsm &&
   cGhcWithNativeCodeGen /= "YES"
      = let dflags' = dflags { hscTarget = HscLlvm }
            warn = "No native code generator, so using LLVM"
        in loop dflags' warn
 | hscTarget dflags == HscLlvm &&
   not ((arch == ArchX86_64) && (os == OSLinux || os == OSDarwin || os == OSFreeBSD)) &&
   not ((isARM arch) && (os == OSLinux)) &&
   (not (gopt Opt_Static dflags) || gopt Opt_PIC dflags)
    = if cGhcWithNativeCodeGen == "YES"
      then let dflags' = dflags { hscTarget = HscAsm }
               warn = "Using native code generator rather than LLVM, as LLVM is incompatible with -fPIC and -dynamic on this platform"
           in loop dflags' warn
      else throwGhcException $ CmdLineError "Can't use -fPIC or -dynamic on this platform"
 | os == OSDarwin &&
   arch == ArchX86_64 &&
   not (gopt Opt_PIC dflags)
    = loop (gopt_set dflags Opt_PIC)
           "Enabling -fPIC as it is always on for this platform"
 | otherwise = (dflags, [])
    where loc = mkGeneralSrcSpan (fsLit "when making flags consistent")
          loop updated_dflags warning
              = case makeDynFlagsConsistent updated_dflags of
                (dflags', ws) -> (dflags', L loc warning : ws)
          platform = targetPlatform dflags
          arch = platformArch platform
          os   = platformOS   platform

--------------------------------------------------------------------------
-- Do not use unsafeGlobalDynFlags!
--
-- unsafeGlobalDynFlags is a hack, necessary because we need to be able
-- to show SDocs when tracing, but we don't always have DynFlags
-- available.
--
-- Do not use it if you can help it. You may get the wrong value, or this
-- panic!

GLOBAL_VAR(v_unsafeGlobalDynFlags, panic "v_unsafeGlobalDynFlags: not initialised", DynFlags)

unsafeGlobalDynFlags :: DynFlags
unsafeGlobalDynFlags = unsafePerformIO $ readIORef v_unsafeGlobalDynFlags

setUnsafeGlobalDynFlags :: DynFlags -> IO ()
setUnsafeGlobalDynFlags = writeIORef v_unsafeGlobalDynFlags

-- -----------------------------------------------------------------------------
-- SSE and AVX

-- TODO: Instead of using a separate predicate (i.e. isSse2Enabled) to
-- check if SSE is enabled, we might have x86-64 imply the -msse2
-- flag.

data SseVersion = SSE1
                | SSE2
                | SSE3
                | SSE4
                | SSE42
                deriving (Eq, Ord)

isSseEnabled :: DynFlags -> Bool
isSseEnabled dflags = case platformArch (targetPlatform dflags) of
    ArchX86_64 -> True
    ArchX86    -> sseVersion dflags >= Just SSE1
    _          -> False

isSse2Enabled :: DynFlags -> Bool
isSse2Enabled dflags = case platformArch (targetPlatform dflags) of
    ArchX86_64 -> -- SSE2 is fixed on for x86_64.  It would be
                  -- possible to make it optional, but we'd need to
                  -- fix at least the foreign call code where the
                  -- calling convention specifies the use of xmm regs,
                  -- and possibly other places.
                  True
    ArchX86    -> sseVersion dflags >= Just SSE2
    _          -> False

isSse4_2Enabled :: DynFlags -> Bool
isSse4_2Enabled dflags = sseVersion dflags >= Just SSE42

isAvxEnabled :: DynFlags -> Bool
isAvxEnabled dflags = avx dflags || avx2 dflags || avx512f dflags

isAvx2Enabled :: DynFlags -> Bool
isAvx2Enabled dflags = avx2 dflags || avx512f dflags

isAvx512cdEnabled :: DynFlags -> Bool
isAvx512cdEnabled dflags = avx512cd dflags

isAvx512erEnabled :: DynFlags -> Bool
isAvx512erEnabled dflags = avx512er dflags

isAvx512fEnabled :: DynFlags -> Bool
isAvx512fEnabled dflags = avx512f dflags

isAvx512pfEnabled :: DynFlags -> Bool
isAvx512pfEnabled dflags = avx512pf dflags

-- -----------------------------------------------------------------------------
-- Linker/compiler information

-- LinkerInfo contains any extra options needed by the system linker.
data LinkerInfo
  = GnuLD    [Option]
  | GnuGold  [Option]
  | DarwinLD [Option]
  | SolarisLD [Option]
  | UnknownLD
  deriving Eq

-- CompilerInfo tells us which C compiler we're using
data CompilerInfo
   = GCC
   | Clang
   | AppleClang
   | AppleClang51
   | UnknownCC
   deriving Eq

-- -----------------------------------------------------------------------------
-- RTS hooks

-- Convert sizes like "3.5M" into integers
decodeSize :: String -> Integer
decodeSize str
  | c == ""      = truncate n
  | c == "K" || c == "k" = truncate (n * 1000)
  | c == "M" || c == "m" = truncate (n * 1000 * 1000)
  | c == "G" || c == "g" = truncate (n * 1000 * 1000 * 1000)
  | otherwise            = throwGhcException (CmdLineError ("can't decode size: " ++ str))
  where (m, c) = span pred str
        n      = readRational m
        pred c = isDigit c || c == '.'

foreign import ccall unsafe "setHeapSize"       setHeapSize       :: Int -> IO ()
foreign import ccall unsafe "enableTimingStats" enableTimingStats :: IO ()
