{-# LANGUAGE GADTs, GeneralizedNewtypeDeriving, TypeOperators, UndecidableInstances #-}
-- | A carrier for 'Parse' effects suitable for use in the repl, tests, etc.
module Control.Carrier.Parse.Simple
( -- * Parse effect
  module Control.Effect.Parse
  -- * Parse carrier
, ParseC(..)
, runParse
) where

import qualified Assigning.Assignment as Assignment
import           Control.Effect.Error
import           Control.Effect.Carrier
import           Control.Effect.Parse
import           Control.Effect.Reader
import           Control.Exception
import           Control.Monad.IO.Class
import           Data.Blob
import           Parsing.Parser
import           Parsing.TreeSitter

runParse :: Duration -> ParseC m a -> m a
runParse timeout = runReader timeout . runParseC

newtype ParseC m a = ParseC { runParseC :: ReaderC Duration m a }
  deriving (Applicative, Functor, Monad, MonadIO)

instance ( Carrier sig m
         , Member (Error SomeException) sig
         , MonadIO m
         )
      => Carrier (Parse :+: sig) (ParseC m) where
  eff (L (Parse parser blob k)) = ParseC (ask @Duration) >>= \ timeout -> case parser of
    UnmarshalParser language
      ->  either (throwError . toException) k
      =<< parseToPreciseAST timeout language blob

    AssignmentParser language assignment
      ->  either (throwError . toException) k . Assignment.assign (blobSource blob) assignment
      =<< either (throwError . toException) pure =<< parseToAST timeout language blob

  eff (R other) = ParseC (send (handleCoercible other))
