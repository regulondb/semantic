{-# LANGUAGE GADTs #-}
module Command
( module C
) where

import Command.Diff as C
import Command.Parse as C
import Control.Monad.Free.Freer
import Prologue
import Source

data CommandF f where
  ReadFile :: FilePath -> CommandF SourceBlob

type Command = Freer CommandF
