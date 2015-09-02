module Lib where

import Language.Haskell.TH.Quote
import Language.Haskell.TH.Syntax

exploit :: QuasiQuoter
exploit = QuasiQuoter
  { quoteExp  = undefined
  , quotePat  = undefined
  , quoteType = undefined
  , quoteDec  = \_ -> runIO (putStrLn "Woops.") >> return []
  }
