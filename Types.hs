{-# LANGUAGE TemplateHaskell, OverloadedStrings #-}
module Types (BuildStatus(..), Package(..), UUID) where

import qualified Data.Text as T
import           Data.MessagePack

type UUID     = T.Text

data BuildStatus = BuildStart UUID
                 | BuildFinished UUID T.Text

data Package = Package { pkgName :: String }
               deriving (Show)

$(deriveObject True ''BuildStatus)
$(deriveObject True ''Package)
