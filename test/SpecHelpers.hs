{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module SpecHelpers
( module X
, runBuilder
, diffFilePaths
, parseFilePath
, readFilePathPair
, runTaskOrDie
, runParseWithConfig
, TaskSession(..)
, testEvaluating
, toList
, Config
, LogQueue
, StatQueue
, lookupDeclaration
, lookupMembers
, EdgeLabel(..)
, TestEvaluatingResult
, TestEvaluatingState
, evaluateProject
, moduleLookup
) where

import qualified Analysis.File as File
import           Analysis.Name as X
import           Analysis.Project as X
import           Control.Abstract
import           Control.Carrier.Fresh.Strict
import           Control.Carrier.Lift
import           Control.Carrier.Parse.Simple
import           Control.Carrier.Reader as X
import           Control.Carrier.Resumable.Either
import           Control.Carrier.State.Strict
import qualified Control.Carrier.Trace.Ignoring as Trace.Ignoring
import           Control.Exception (displayException)
import           Control.Monad as X
import           Data.Abstract.Address.Precise as X
import           Data.Abstract.Evaluatable
import           Data.Abstract.FreeVariables as X
import qualified Data.Abstract.Heap as Heap
import           Data.Abstract.Module as X
import           Data.Abstract.ModuleTable as X hiding (lookup)
import qualified Data.Abstract.ModuleTable as ModuleTable
import qualified Data.Abstract.ScopeGraph as ScopeGraph
import           Data.Abstract.Value.Concrete (Value (..), ValueError, runValueError)
import           Data.Blob as X
import           Data.Blob.IO as X
import           Data.ByteString as X (ByteString)
import           Data.ByteString.Builder (Builder, toLazyByteString)
import           Data.ByteString.Lazy (toStrict)
import           Data.Edit as X
import           Data.Foldable (toList)
import           Data.Functor.Listable as X
import           Data.Language as X hiding (Precise)
import           Data.List.NonEmpty as X (NonEmpty (..))
import           Data.Maybe as X
import           Data.Monoid as X (First (..), Last (..), Monoid (..))
import           Data.Proxy as X
import           Data.Semigroup as X (Semigroup (..))
import           Data.Semilattice.Lower as X
import           Data.Sum as Sum
import           Data.Term as X
import           Data.Traversable as X (for)
import           Debug.Trace as X (traceM, traceShowM)
import           Parsing.Parser as X
import           Semantic.Api hiding (Blob, BlobPair, File)
import           Semantic.Config (Config (..), optionsLogLevel)
import           Semantic.Graph (analysisParsers, runHeap, runScopeGraph)
import           Semantic.Task as X
import           Semantic.Telemetry (LogQueue, StatQueue)
import           Semantic.Util as X
import           Source.Range as X hiding (end, point, start)
import           Source.Source as X (Source)
import           Source.Span as X hiding (HasSpan (..), end, point, start)
import qualified Source.Span
import           System.Exit (die)
import qualified System.Path as Path
import           Test.Hspec as X (Spec, SpecWith, around, context, describe, it, parallel, pendingWith, runIO, xit)
import           Test.Hspec.Expectations as X
import           Test.Hspec.LeanCheck as X
import           Test.LeanCheck as X
import           Unsafe.Coerce (unsafeCoerce)

instance Lower X.Span where
  lowerBound = Source.Span.point (Pos 1 1)

runBuilder :: Builder -> ByteString
runBuilder = toStrict . toLazyByteString

-- | Returns an s-expression formatted diff for the specified FilePath pair.
diffFilePaths :: TaskSession -> Path.RelFile -> Path.RelFile -> IO ByteString
diffFilePaths session p1 p2 = do
  blobs <- readFilePathPair p1 p2
  builder <- runTask session (runParse (configTreeSitterParseTimeout (config session)) (parseDiffBuilder DiffSExpression [ blobs ]))
  either (die . displayException) (pure . runBuilder) builder

-- | Returns an s-expression parse tree for the specified path.
parseFilePath :: TaskSession -> Path.RelFile -> IO (Either SomeException ByteString)
parseFilePath session path = do
  blob <- readBlobFromFile (File.fromPath path)
  res <- runTask session . runParse (configTreeSitterParseTimeout (config session)) . runReader defaultLanguageModes $ parseTermBuilder TermSExpression (toList blob)
  pure (runBuilder <$> res)

runParseWithConfig :: Has (Reader Config) sig m => ParseC m a -> m a
runParseWithConfig task = asks configTreeSitterParseTimeout >>= \ timeout -> runParse timeout task

-- | Read two files to a BlobPair.
readFilePathPair :: Path.RelFile -> Path.RelFile -> IO BlobPair
readFilePathPair p1 p2 = readFilePair (File.fromPath p1) (File.fromPath p2)

-- Run a Task and call `die` if it returns an Exception.
runTaskOrDie :: ParseC TaskC a -> IO a
runTaskOrDie task = runTaskWithOptions defaultOptions { optionsLogLevel = Nothing } (runParseWithConfig task) >>= either (die . displayException) pure

type TestEvaluatingC term
  = ResumableC (BaseError (AddressError Precise (Val term)))
  ( ResumableC (BaseError (ValueError term Precise))
  ( ResumableC (BaseError ResolutionError)
  ( ResumableC (BaseError (EvalError term Precise (Val term)))
  ( ResumableC (BaseError (HeapError Precise))
  ( ResumableC (BaseError (ScopeError Precise))
  ( ResumableC (BaseError (UnspecializedError Precise (Val term)))
  ( ResumableC (BaseError (LoadError Precise (Val term)))
  ( StateC (Heap Precise Precise (Val term))
  ( StateC (ScopeGraph Precise)
  ( FreshC
  ( Trace.Ignoring.TraceC
  ( LiftC IO))))))))))))
type TestEvaluatingErrors term
  = '[ BaseError (AddressError Precise (Val term))
     , BaseError (ValueError term Precise)
     , BaseError ResolutionError
     , BaseError (EvalError term Precise (Val term))
     , BaseError (HeapError Precise)
     , BaseError (ScopeError Precise)
     , BaseError (UnspecializedError Precise (Val term))
     , BaseError (LoadError Precise (Val term))
     ]
type TestEvaluatingState term a
  = ( ScopeGraph Precise
    , ( Heap Precise Precise (Val term)
      , Either (SomeError (Sum.Sum (TestEvaluatingErrors term))) a
      )
    )
type TestEvaluatingResult term = ModuleTable (Module (ModuleResult Precise (Val term)))
testEvaluating :: Evaluator term Precise (Val term) (TestEvaluatingC term) a
               -> IO (TestEvaluatingState term a)
testEvaluating
  = runM
  . Trace.Ignoring.runTrace
  . fmap snd
  . runFresh 0
  . runEvaluator
  . runScopeGraph
  . runHeap
  . fmap reassociate
  . runLoadError
  . runUnspecialized
  . runScopeError
  . runHeapError
  . runEvalError
  . runResolutionError
  . runValueError
  . runAddressError

type Val term = Value term Precise

evaluateProject :: (HasPrelude lang, SLanguage lang) => TaskSession -> Proxy lang -> [FilePath] -> IO (TestEvaluatingState term (TestEvaluatingResult term))
evaluateProject session proxy = case parserForLanguage analysisParsers lang of
  Just (SomeParser parser) -> unsafeCoerce . testEvaluating <=< evaluateProject' session proxy parser
  _                        -> error $ "analysis not supported for " <> show lang
  where lang = reflect proxy


members :: EdgeLabel
        -> Heap Precise Precise (Value term Precise)
        -> ScopeGraph Precise
        -> Value term Precise
        -> Maybe [Name]
members edgeLabel heap scopeGraph (Data.Abstract.Value.Concrete.Object frame)    = frameNames [ edgeLabel ] heap scopeGraph frame
members edgeLabel heap scopeGraph (Class _ _ frame) = frameNames [ edgeLabel ] heap scopeGraph frame
members _ _ _ _                                     = Nothing

frameNames :: [ EdgeLabel ]
           -> Heap Precise Precise (Value term Precise)
           -> ScopeGraph Precise
           -> Precise
           -> Maybe [ Name ]
frameNames edge heap scopeGraph frame = do
  scopeAddress <- Heap.scopeLookup frame heap
  scope <- ScopeGraph.lookupScope scopeAddress scopeGraph
  pure (unDeclaration <$> toList (ScopeGraph.declarationNames edge scope scopeGraph))

lookupMembers :: Name -> EdgeLabel -> (Precise, Precise) -> Heap Precise Precise (Value term Precise) -> ScopeGraph Precise -> Maybe [ Name ]
lookupMembers name edgeLabel scopeAndFrame heap scopeGraph =
  (lookupDeclaration name scopeAndFrame heap scopeGraph >>= members edgeLabel heap scopeGraph . Prelude.head)

lookupDeclaration :: Name -> (Precise, Precise) -> Heap Precise Precise (Value term Precise) -> ScopeGraph Precise -> Maybe [ Value term Precise ]
lookupDeclaration name (currentScope, currentFrame) heap scopeGraph = do
  path <- ScopeGraph.lookupScopePath name currentScope scopeGraph
  frameAddress <- Heap.lookupFrameAddress path currentFrame heap
  toList <$> Heap.getSlotValue (Slot frameAddress (Heap.pathPosition path)) heap

moduleLookup :: FilePath -> ModuleTable a -> Maybe a
moduleLookup = ModuleTable.lookup . Path.absRel
