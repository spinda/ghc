%
% (c) The GRASP/AQUA Project, Glasgow University, 1993-1998
%
\section[GHC_Stats]{Statistics for per-module compilations}

\begin{code}
module HscStats ( ppSourceStats ) where

#include "HsVersions.h"

import HsSyn
import Outputable
import Char		( isSpace )
\end{code}

%************************************************************************
%*									*
\subsection{Statistics}
%*									*
%************************************************************************

\begin{code}
ppSourceStats short (HsModule name version exports imports decls _ src_loc)
 = (if short then hcat else vcat)
        (map pp_val
	       [("ExportAll        ", export_all), -- 1 if no export list
		("ExportDecls      ", export_ds),
		("ExportModules    ", export_ms),
		("Imports          ", import_no),
		("  ImpQual        ", import_qual),
		("  ImpAs          ", import_as),
		("  ImpAll         ", import_all),
		("  ImpPartial     ", import_partial),
		("  ImpHiding      ", import_hiding),
		("FixityDecls      ", fixity_ds),
		("DefaultDecls     ", default_ds),
	      	("TypeDecls        ", type_ds),
	      	("DataDecls        ", data_ds),
	      	("NewTypeDecls     ", newt_ds),
	      	("DataConstrs      ", data_constrs),
		("DataDerivings    ", data_derivs),
	      	("ClassDecls       ", class_ds),
	      	("ClassMethods     ", class_method_ds),
	      	("DefaultMethods   ", default_method_ds),
	      	("InstDecls        ", inst_ds),
	      	("InstMethods      ", inst_method_ds),
	      	("TypeSigs         ", bind_tys),
	      	("ValBinds         ", val_bind_ds),
	      	("FunBinds         ", fn_bind_ds),
	      	("InlineMeths      ", method_inlines),
		("InlineBinds      ", bind_inlines),
--	      	("SpecialisedData  ", data_specs),
--	      	("SpecialisedInsts ", inst_specs),
	      	("SpecialisedMeths ", method_specs),
	      	("SpecialisedBinds ", bind_specs)
	       ])
  where
    pp_val (str, 0) = empty
    pp_val (str, n) 
      | not short   = hcat [text str, int n]
      | otherwise   = hcat [text (trim str), equals, int n, semi]
    
    trim ls     = takeWhile (not.isSpace) (dropWhile isSpace ls)

    fixity_ds   = length [() | FixD d <- decls]
		-- NB: this omits fixity decls on local bindings and
		-- in class decls.  ToDo

    tycl_decls  = [d | TyClD d <- decls]
    (class_ds, data_ds, newt_ds, type_ds, _) = countTyClDecls tycl_decls

    inst_decls  = [d | InstD d <- decls]
    inst_ds     = length inst_decls
    default_ds  = length [() | DefD _ <- decls]
    val_decls   = [d | ValD d <- decls]

    real_exports = case exports of { Nothing -> []; Just es -> es }
    n_exports  	 = length real_exports
    export_ms  	 = length [() | IEModuleContents _ <- real_exports]
    export_ds  	 = n_exports - export_ms
    export_all 	 = case exports of { Nothing -> 1; other -> 0 }

    (val_bind_ds, fn_bind_ds, bind_tys, bind_specs, bind_inlines)
	= count_binds (foldr ThenBinds EmptyBinds val_decls)

    (import_no, import_qual, import_as, import_all, import_partial, import_hiding)
	= foldr add6 (0,0,0,0,0,0) (map import_info imports)
    (data_constrs, data_derivs)
	= foldr add2 (0,0) (map data_info tycl_decls)
    (class_method_ds, default_method_ds)
	= foldr add2 (0,0) (map class_info tycl_decls)
    (inst_method_ds, method_specs, method_inlines)
	= foldr add3 (0,0,0) (map inst_info inst_decls)


    count_binds EmptyBinds        = (0,0,0,0,0)
    count_binds (ThenBinds b1 b2) = count_binds b1 `add5` count_binds b2
    count_binds (MonoBind b sigs _) = case (count_monobinds b, count_sigs sigs) of
				        ((vs,fs),(ts,_,ss,is)) -> (vs,fs,ts,ss,is)

    count_monobinds EmptyMonoBinds	  	   = (0,0)
    count_monobinds (AndMonoBinds b1 b2)  	   = count_monobinds b1 `add2` count_monobinds b2
    count_monobinds (PatMonoBind (VarPatIn n) r _) = (1,0)
    count_monobinds (PatMonoBind p r _)            = (0,1)
    count_monobinds (FunMonoBind f _ m _)          = (0,1)

    count_mb_monobinds (Just mbs) = count_monobinds mbs
    count_mb_monobinds Nothing	  = (0,0)

    count_sigs sigs = foldr add4 (0,0,0,0) (map sig_info sigs)

    sig_info (Sig _ _ _)            = (1,0,0,0)
    sig_info (ClassOpSig _ _ _ _)   = (0,1,0,0)
    sig_info (SpecSig _ _ _)        = (0,0,1,0)
    sig_info (InlineSig _ _ _)      = (0,0,0,1)
    sig_info (NoInlineSig _ _ _)    = (0,0,0,1)
    sig_info _                      = (0,0,0,0)

    import_info (ImportDecl _ _ qual as spec _)
	= add6 (1, qual_info qual, as_info as, 0,0,0) (spec_info spec)
    qual_info False  = 0
    qual_info True   = 1
    as_info Nothing  = 0
    as_info (Just _) = 1
    spec_info Nothing 	        = (0,0,0,1,0,0)
    spec_info (Just (False, _)) = (0,0,0,0,1,0)
    spec_info (Just (True, _))  = (0,0,0,0,0,1)

    data_info (TyData {tcdNCons = nconstrs, tcdDerivs = derivs})
	= (nconstrs, case derivs of {Nothing -> 0; Just ds -> length ds})
    data_info other = (0,0)

    class_info decl@(ClassDecl {})
	= case count_sigs (tcdSigs decl) of
	    (_,classops,_,_) ->
	       (classops, addpr (count_mb_monobinds (tcdMeths decl)))
    class_info other = (0,0)

    inst_info (InstDecl _ inst_meths inst_sigs _ _)
	= case count_sigs inst_sigs of
	    (_,_,ss,is) ->
	       (addpr (count_monobinds inst_meths), ss, is)

    addpr :: (Int,Int) -> Int
    add1  :: Int -> Int -> Int
    add2  :: (Int,Int) -> (Int,Int) -> (Int, Int)
    add3  :: (Int,Int,Int) -> (Int,Int,Int) -> (Int, Int, Int)
    add4  :: (Int,Int,Int,Int) -> (Int,Int,Int,Int) -> (Int, Int, Int, Int)
    add5  :: (Int,Int,Int,Int,Int) -> (Int,Int,Int,Int,Int) -> (Int, Int, Int, Int, Int)
    add6  :: (Int,Int,Int,Int,Int,Int) -> (Int,Int,Int,Int,Int,Int) -> (Int, Int, Int, Int, Int, Int)

    addpr (x,y) = x+y
    add1 x1 y1  = x1+y1
    add2 (x1,x2) (y1,y2) = (x1+y1,x2+y2)
    add3 (x1,x2,x3) (y1,y2,y3) = (x1+y1,x2+y2,x3+y3)
    add4 (x1,x2,x3,x4) (y1,y2,y3,y4) = (x1+y1,x2+y2,x3+y3,x4+y4)
    add5 (x1,x2,x3,x4,x5) (y1,y2,y3,y4,y5) = (x1+y1,x2+y2,x3+y3,x4+y4,x5+y5)
    add6 (x1,x2,x3,x4,x5,x6) (y1,y2,y3,y4,y5,y6) = (x1+y1,x2+y2,x3+y3,x4+y4,x5+y5,x6+y6)
\end{code}









