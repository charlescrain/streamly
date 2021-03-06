{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE UndecidableInstances      #-} -- XXX

-- |
-- Module      : Streamly.Core
-- Copyright   : (c) 2017 Harendra Kumar
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
--
module Streamly.Core
    (
      MonadAsync

    -- * Streams
    , Stream (..)

    -- * Construction
    , scons
    , snil

    -- * Composition
    , interleave

    -- * Concurrent Stream Vars (SVars)
    , SVar
    , SVarSched (..)
    , SVarTag (..)
    , SVarStyle (..)
    , newEmptySVar
    , newStreamVar1
    , newStreamVar2
    , joinStreamVar2
    , fromStreamVar
    , toStreamVar

    -- * Concurrent Streams
    , parAlt
    , parLeft
    )
where

import           Control.Applicative         (Alternative (..))
import           Control.Concurrent          (ThreadId, forkIO,
                                              myThreadId, threadDelay)
import           Control.Concurrent.MVar     (MVar, newEmptyMVar, tryTakeMVar,
                                              tryPutMVar, takeMVar)
import           Control.Exception           (SomeException (..))
import qualified Control.Exception.Lifted    as EL
import           Control.Monad               (MonadPlus(..), mzero, when)
import           Control.Monad.Base          (MonadBase (..), liftBaseDefault)
import           Control.Monad.Catch         (MonadThrow, throwM)
import           Control.Monad.Error.Class   (MonadError(..))
import           Control.Monad.IO.Class      (MonadIO(..))
import           Control.Monad.Reader.Class  (MonadReader(..))
import           Control.Monad.State.Class   (MonadState(..))
import           Control.Monad.Trans.Class   (MonadTrans (lift))
import           Control.Monad.Trans.Control (MonadBaseControl, liftBaseWith)
import           Data.Atomics                (atomicModifyIORefCAS,
                                              atomicModifyIORefCAS_)
import           Data.Concurrent.Queue.MichaelScott (LinkedQueue, newQ, pushL,
                                                     tryPopR, nullQ)
import           Data.Functor                (void)
import           Data.IORef                  (IORef, modifyIORef, newIORef,
                                              readIORef)
import           Data.Maybe                  (isNothing)
import           Data.Semigroup              (Semigroup(..))
import           Data.Set                    (Set)
import qualified Data.Set                    as S

------------------------------------------------------------------------------
-- Parent child thread communication type
------------------------------------------------------------------------------

-- | Events that a child thread may send to a parent thread.
data ChildEvent a =
      ChildYield a
    | ChildStop ThreadId (Maybe SomeException)

------------------------------------------------------------------------------
-- State threaded around the monad for thread management
------------------------------------------------------------------------------

-- | Conjunction is used for monadic/product style composition. Disjunction is
-- used for fold/sum style composition. We need to distiguish the two types of
-- SVars so that the scheduling of the two is independent.
data SVarTag = Conjunction | Disjunction deriving Eq

-- | For fairly interleaved parallel composition the sched policy is FIFO
-- whereas for left biased parallel composition it is LIFO.
data SVarSched = LIFO | FIFO deriving Eq

-- | Identify the type of the SVar. Two computations using the same style can
-- be scheduled on the same SVar.
data SVarStyle = SVarStyle SVarTag SVarSched deriving Eq

-- | An SVar or a Stream Var is a conduit to the output from multiple streams
-- running concurrently and asynchronously. An SVar can be thought of as an
-- asynchronous IO handle. We can write any number of streams to an SVar in a
-- non-blocking manner and then read them back at any time at any pace.  The
-- SVar would run the streams asynchronously and accumulate results. An SVar
-- may not really execute the stream completely and accumulate all the results.
-- However, it ensures that the reader can read the results at whatever paces
-- it wants to read. The SVar monitors and adapts to the consumer's pace.
--
-- An SVar is a mini scheduler, it has an associated runqueue that holds the
-- stream tasks to be picked and run by a pool of worker threads. It has an
-- associated output queue where the output stream elements are placed by the
-- worker threads. A doorBell is used by the worker threads to intimate the
-- consumer thread about availability of new results in the output queue. More
-- workers are added to the SVar by 'fromStreamVar' on demand if the output
-- produced is not keeping pace with the consumer. On bounded SVars, workers
-- block on the output queue to provide throttling of the producer  when the
-- consumer is not pulling fast enough.  The number of workers may even get
-- reduced depending on the consuming pace.
--
-- New work is enqueued either at the time of creation of the SVar or as a
-- result of executing the parallel combinators i.e. '<|' and '<|>' when the
-- already enqueued computations get evaluated. See 'joinStreamVar2'.
--
data SVar m a =
       SVar { outputQueue    :: IORef [ChildEvent a]
            , doorBell       :: MVar Bool -- wakeup mechanism for outQ
            , enqueue        :: Stream m a -> IO ()
            , runqueue       :: m ()
            , runningThreads :: IORef (Set ThreadId)
            , queueEmpty     :: m Bool
            , svarStyle      :: SVarStyle
            }

------------------------------------------------------------------------------
-- The stream type
------------------------------------------------------------------------------

-- TBD use a functor instead of the bare type a?
-- XXX remove the Maybe, use "empty" as the base case

-- | Represents a monadic stream of values of type 'a' constructed using
-- actions in monad 'm'. Streams can be composed sequentially or in parallel;
-- in product style compositions (monadic bind multiplies streams in a ListT
-- fashion) or in sum style compositions like 'Semigroup', 'Monoid',
-- 'Alternative' or variants of these.
newtype Stream m a =
    Stream {
        runStream :: forall r.
               Maybe (SVar m a)               -- local state
            -> m r                               -- stop
            -> (a -> Maybe (Stream m a) -> m r)  -- yield
            -> m r
    }

-- | A monad that can perform asynchronous/concurrent IO operations. Streams
-- that can be composed concurrently require the underlying monad to be
-- 'MonadAsync'.
type MonadAsync m = (MonadIO m, MonadBaseControl IO m, MonadThrow m)

scons :: a -> Maybe (Stream m a) -> Stream m a
scons a r = Stream $ \_ _ yld -> yld a r

snil :: Stream m a
snil = Stream $ \_ stp _ -> stp

------------------------------------------------------------------------------
-- Semigroup
------------------------------------------------------------------------------

-- | '<>' concatenates two streams sequentially i.e. the first stream is
-- exhausted completely before yielding any element from the second stream.
instance Semigroup (Stream m a) where
    m1 <> m2 = go m1
        where
        go (Stream m) = Stream $ \_ stp yld ->
                let stop = (runStream m2) Nothing stp yld
                    yield a Nothing  = yld a (Just m2)
                    yield a (Just r) = yld a (Just (go r))
                in m Nothing stop yield

------------------------------------------------------------------------------
-- Monoid
------------------------------------------------------------------------------

instance Monoid (Stream m a) where
    mempty = Stream $ \_ stp _ -> stp
    mappend = (<>)

------------------------------------------------------------------------------
-- Interleave
------------------------------------------------------------------------------

-- | Same as '<=>'.
interleave :: Stream m a -> Stream m a -> Stream m a
interleave m1 m2 = Stream $ \_ stp yld -> do
    let stop = (runStream m2) Nothing stp yld
        yield a Nothing  = yld a (Just m2)
        yield a (Just r) = yld a (Just (interleave m2 r))
    (runStream m1) Nothing stop yield

------------------------------------------------------------------------------
-- Spawning threads and collecting result in streamed fashion
------------------------------------------------------------------------------

{-# INLINE doFork #-}
doFork :: MonadBaseControl IO m
    => m ()
    -> (SomeException -> m ())
    -> m ThreadId
doFork action exHandler =
    EL.mask $ \restore ->
        liftBaseWith $ \runInIO -> forkIO $ do
            -- XXX test the exception handling
            _ <- runInIO $ EL.catch (restore action) exHandler
            -- XXX restore state here?
            return ()

-- XXX exception safety of all atomic/MVar operations

{-# INLINE send #-}
send :: MonadIO m => SVar m a -> ChildEvent a -> m ()
send sv msg = liftIO $ do
    atomicModifyIORefCAS_ (outputQueue sv) $ \es -> msg : es
    -- XXX need a memory barrier? The wake up must happen only after the
    -- store has finished otherwise we can have lost wakeup problems.
    void $ tryPutMVar (doorBell sv) True

{-# INLINE sendStop #-}
sendStop :: MonadIO m => SVar m a -> m ()
sendStop sv = liftIO myThreadId >>= \tid -> send sv (ChildStop tid Nothing)

-- Note: Left associated compositions can grow this queue to a large size
{-# INLINE enqueueLIFO #-}
enqueueLIFO :: IORef [Stream m a] -> Stream m a -> IO ()
enqueueLIFO q m = atomicModifyIORefCAS_ q $ \ ms -> m : ms

runqueueLIFO :: MonadIO m => SVar m a -> IORef [Stream m a] -> m ()
runqueueLIFO sv q = run

    where

    run = do
        work <- dequeue
        case work of
            Nothing -> sendStop sv
            Just m -> (runStream m) (Just sv) run yield

    sendit a = send sv (ChildYield a)
    yield a Nothing  = sendit a >> run
    yield a (Just r) = sendit a >> (runStream r) (Just sv) run yield

    dequeue = liftIO $ atomicModifyIORefCAS q $ \ ms ->
        case ms of
            [] -> ([], Nothing)
            x : xs -> (xs, Just x)

{-# INLINE enqueueFIFO #-}
enqueueFIFO :: LinkedQueue (Stream m a) -> Stream m a -> IO ()
enqueueFIFO = pushL

runqueueFIFO :: MonadIO m => SVar m a -> LinkedQueue (Stream m a) -> m ()
runqueueFIFO sv q = run

    where

    run = do
        work <- dequeue
        case work of
            Nothing -> sendStop sv
            Just m -> (runStream m) (Just sv) run yield

    dequeue = liftIO $ tryPopR q
    sendit a = send sv (ChildYield a)
    yield a Nothing  = sendit a >> run
    yield a (Just r) = sendit a >> liftIO (enqueueFIFO q r) >> run

-- Thread tracking is needed for two reasons:
--
-- 1) Killing threads on exceptions. Threads may not be allowed to go away by
-- themselves because they may run for significant times before going away or
-- worse they may be stuck in IO and never go away.
--
-- 2) To know when all threads are done.

{-# NOINLINE addThread #-}
addThread :: MonadIO m => SVar m a -> ThreadId -> m ()
addThread sv tid =
    liftIO $ modifyIORef (runningThreads sv) $ (\s -> S.insert tid s)

{-# INLINE delThread #-}
delThread :: MonadIO m => SVar m a -> ThreadId -> m ()
delThread sv tid =
    liftIO $ modifyIORef (runningThreads sv) $ (\s -> S.delete tid s)

{-# INLINE allThreadsDone #-}
allThreadsDone :: MonadIO m => SVar m a -> m Bool
allThreadsDone sv = liftIO $ do
    readIORef (runningThreads sv) >>= return . S.null

{-# NOINLINE handleChildException #-}
handleChildException :: MonadIO m => SVar m a -> SomeException -> m ()
handleChildException sv e = do
    tid <- liftIO myThreadId
    send sv (ChildStop tid (Just e))

{-# NOINLINE pushWorker #-}
pushWorker :: MonadAsync m => SVar m a -> m ()
pushWorker sv =
    doFork (runqueue sv) (handleChildException sv) >>= addThread sv

-- XXX When the queue is LIFO we can put a limit on the number of dispatches.
-- Also, if a worker blocks on the output queue we can decide if we want to
-- block or make it go away entirely, depending on the number of workers and
-- the type of the queue.
{-# INLINE sendWorkerWait #-}
sendWorkerWait :: MonadAsync m => SVar m a -> m ()
sendWorkerWait sv = do
    case svarStyle sv of
        SVarStyle _ LIFO -> liftIO $ threadDelay 200
        SVarStyle _ FIFO -> liftIO $ threadDelay 0

    output <- liftIO $ readIORef (outputQueue sv)
    when (null output) $ do
        done <- queueEmpty sv
        if (not done)
        then (pushWorker sv) >> sendWorkerWait sv
        else void (liftIO $ takeMVar (doorBell sv))

-- | Pull a stream from an SVar.
{-# NOINLINE fromStreamVar #-}
fromStreamVar :: MonadAsync m => SVar m a -> Stream m a
fromStreamVar sv = Stream $ \_ stp yld -> do
    -- XXX if reading the IORef is costly we can use a flag in the SVar to
    -- indicate we are done.
    done <- allThreadsDone sv
    if done
    then stp
    else do
        res <- liftIO $ tryTakeMVar (doorBell sv)
        when (isNothing res) $ sendWorkerWait sv
        list <- liftIO $ atomicModifyIORefCAS (outputQueue sv) $ \x -> ([], x)
        -- To avoid lock overhead we read all events at once instead of reading
        -- one at a time. We just reverse the list to process the events in the
        -- order they arrived. Maybe we can use a queue instead?
        (runStream $ processEvents (reverse list)) Nothing stp yld

    where

    handleException e tid = do
        delThread sv tid
        -- XXX implement kill async exception handling
        -- liftIO $ readIORef (runningThreads sv) >>= mapM_ killThread
        throwM e

    {-# INLINE processEvents #-}
    processEvents [] = Stream $ \_ stp yld -> do
        done <- allThreadsDone sv
        if not done
        then (runStream (fromStreamVar sv)) Nothing stp yld
        else stp

    processEvents (ev : es) = Stream $ \_ stp yld -> do
        let continue = (runStream (processEvents es)) Nothing stp yld
            yield a  = yld a (Just (processEvents es))

        case ev of
            ChildYield a -> yield a
            ChildStop tid e ->
                case e of
                    Nothing -> delThread sv tid >> continue
                    Just ex -> handleException ex tid

getFifoSVar :: MonadIO m => SVarStyle -> IO (SVar m a)
getFifoSVar ctype = do
    outQ    <- newIORef []
    outQMv  <- newEmptyMVar
    running <- newIORef S.empty
    q       <- newQ
    let sv =
            SVar { outputQueue    = outQ
                    , doorBell       = outQMv
                    , runningThreads = running
                    , runqueue       = runqueueFIFO sv q
                    , enqueue        = pushL q
                    , queueEmpty     = liftIO $ nullQ q
                    , svarStyle        = ctype
                    }
     in return sv

getLifoSVar :: MonadIO m => SVarStyle -> IO (SVar m a)
getLifoSVar ctype = do
    outQ    <- newIORef []
    outQMv  <- newEmptyMVar
    running <- newIORef S.empty
    q <- newIORef []
    let checkEmpty = liftIO (readIORef q) >>= return . null
    let sv =
            SVar { outputQueue    = outQ
                    , doorBell       = outQMv
                    , runningThreads = running
                    , runqueue       = runqueueLIFO sv q
                    , enqueue        = enqueueLIFO q
                    , queueEmpty     = checkEmpty
                    , svarStyle        = ctype
                    }
     in return sv

-- | Create a new empty SVar.
newEmptySVar :: MonadAsync m => SVarStyle -> m (SVar m a)
newEmptySVar style = do
    sv <- liftIO $
        case style of
            SVarStyle _ FIFO -> do
                c <- getFifoSVar style
                return c
            SVarStyle _ LIFO -> do
                c <- getLifoSVar style
                return c
    return sv

-- | Create a new SVar and enqueue one stream computation on it.
newStreamVar1 :: MonadAsync m => SVarStyle -> Stream m a -> m (SVar m a)
newStreamVar1 style m = do
    sv <- newEmptySVar style
    -- Note: We must have all the work on the queue before sending the
    -- pushworker, otherwise the pushworker may exit before we even get a
    -- chance to push.
    liftIO $ (enqueue sv) m
    pushWorker sv
    return sv

-- | Create a new SVar and enqueue two stream computations on it.
newStreamVar2 :: MonadAsync m
    => SVarStyle -> Stream m a -> Stream m a -> m (SVar m a)
newStreamVar2 style m1 m2 = do
    -- Note: We must have all the work on the queue before sending the
    -- pushworker, otherwise the pushworker may exit before we even get a
    -- chance to push.
    sv <- liftIO $
        case style of
            SVarStyle _ FIFO -> do
                c <- getFifoSVar style
                (enqueue c) m1 >> (enqueue c) m2
                return c
            SVarStyle _ LIFO -> do
                c <- getLifoSVar style
                (enqueue c) m2 >> (enqueue c) m1
                return c
    pushWorker sv
    return sv

-- | Write a stream to an 'SVar' in a non-blocking manner. The stream can then
-- be read back from the SVar using 'fromSVar'.
toStreamVar :: MonadAsync m => SVar m a -> Stream m a -> m ()
toStreamVar sv m = do
    liftIO $ (enqueue sv) m
    done <- allThreadsDone sv
    -- XXX there may be a race here unless we are running in the consumer
    -- thread. This is safe only when called from the consumer thread or when
    -- no consumer is present.
    when done $ pushWorker sv

------------------------------------------------------------------------------
-- Running streams concurrently
------------------------------------------------------------------------------

-- Concurrency rate control. Our objective is to create more threads on demand
-- if the consumer is running faster than us. As soon as we encounter an
-- Alternative composition we create a push pull pair of threads. We use a
-- channel for communication between the consumer pulling from the channel and
-- the producer who pushing to the channel. The producer creates more threads
-- if no output is seen on the channel, that is the consumer is running faster.
-- However this mechanism can be problematic if the initial production latency
-- is high, we may end up creating too many threads. So we need some way to
-- monitor and use the latency as well.
--
-- TBD We may run computations at the lower level of the composition tree
-- serially even if they are composed using a parallel combinator. We can use
-- <> in place of <| and <=> in place of <|>. If we find that a parallel
-- channel immediately above a computation becomes empty we can switch to
-- parallelizing the computation.  For that we can use a state flag to fork the
-- rest of the computation at any point of time inside the Monad bind operation
-- if the consumer is running at a faster speed.
--
-- TBD the alternative composition allows us to dispatch a chunkSize of only 1.
-- If we have to dispatch in arbitrary chunksizes we will need to compose the
-- parallel actions using a data constructor (Free Alternative) instead so that
-- we can divide it in chunks of arbitrary size before dispatch. If the stream
-- is composed of hierarchically composed grains of different sizes then we can
-- always switch to a desired granularity depending on the consumer speed.
--
-- TBD for pure work (when we are not in the IO monad) we can divide it into
-- just the number of CPUs.

{-# NOINLINE withNewSVar2 #-}
withNewSVar2 :: MonadAsync m
    => SVarStyle -> Stream m a -> Stream m a -> Stream m a
withNewSVar2 style m1 m2 = Stream $ \_ stp yld -> do
    sv <- newStreamVar2 style m1 m2
    (runStream (fromStreamVar sv)) Nothing stp yld

-- | Join two computations on the currently running 'SVar' queue for concurrent
-- execution. The 'SVarStyle' required by the current composition context is
-- passed as one of the parameters. If the style does not match with the style
-- of the current 'SVar' we create a new 'SVar' and schedule the computations
-- on that. The newly created SVar joins as one of the computations on the
-- current SVar queue.
--
-- When we are using parallel composition, an SVar is passed around as a state
-- variable. We try to schedule a new parallel computation on the SVar passed
-- to us. The first time, when no SVar exists, a new SVar is created.
-- Subsequently, 'joinStreamVar2' may get called when a computation already
-- scheduled on the SVar is further evaluated. For example, when (a \<|> b) is
-- evaluated it calls a 'joinStreamVar2' to put 'a' and 'b' on the current scheduler
-- queue.  However, if the scheduling and composition style of the new
-- computation being scheduled is different than the style of the current SVar,
-- then we create a new SVar and schedule it on that.
--
-- For example:
--
-- * (x \<|> y) \<|> (t \<|> u) -- all of them get scheduled on the same SVar
-- * (x \<|> y) \<|> (t \<| u) -- @t@ and @u@ get scheduled on a new child SVar
--   because of the scheduling policy change.
-- * if we 'adapt' a stream of type 'AsyncT' to a stream of type
--   'ParallelT', we create a new SVar at the transitioning bind.
-- * When the stream is switching from disjunctive composition to conjunctive
--   composition and vice-versa we create a new SVar to isolate the scheduling
--   of the two.
--
{-# INLINE joinStreamVar2 #-}
joinStreamVar2 :: MonadAsync m
    => SVarStyle -> Stream m a -> Stream m a -> Stream m a
joinStreamVar2 style m1 m2 = Stream $ \st stp yld -> do
    case st of
        Just sv | svarStyle sv == style ->
            liftIO ((enqueue sv) m2) >> (runStream m1) st stp yld
        _ -> (runStream (withNewSVar2 style m1 m2)) Nothing stp yld

------------------------------------------------------------------------------
-- Semigroup and Monoid style compositions for parallel actions
------------------------------------------------------------------------------

{-
-- | Same as '<>|'.
parAhead :: Stream m a -> Stream m a -> Stream m a
parAhead = undefined

-- | Sequential composition similar to '<>' except that it can execute the
-- action on the right in parallel ahead of time. Returns the results in
-- sequential order like '<>' from left to right.
(<>|) :: Stream m a -> Stream m a -> Stream m a
(<>|) = parAhead
-}

-- | Same as '<|>'. Since this schedules all the composed streams fairly you
-- cannot fold infinite number of streams using this operation.
{-# INLINE parAlt #-}
parAlt :: MonadAsync m => Stream m a -> Stream m a -> Stream m a
parAlt = joinStreamVar2 (SVarStyle Disjunction FIFO)

-- | Same as '<|'. Since this schedules the left side computation first you can
-- right fold an infinite container using this operator. However a left fold
-- will not work well as it first unpeels the whole structure before scheduling
-- a computation requiring an amount of memory proportional to the size of the
-- structure.
{-# INLINE parLeft #-}
parLeft :: MonadAsync m => Stream m a -> Stream m a -> Stream m a
parLeft = joinStreamVar2 (SVarStyle Disjunction LIFO)

-------------------------------------------------------------------------------
-- Instances (only used for deriving newtype instances)
-------------------------------------------------------------------------------

-- Stream type is not exposed, these instances are only for deriving instances
-- for the newtype wrappers based on Stream.

-- Dummy Instances, defined to enable the definition of other instances that
-- require a Monad constraint.  Must be defined by the newtypes.

instance Monad m => Functor (Stream m) where
    fmap = undefined

instance Monad m => Applicative (Stream m) where
    pure = undefined
    (<*>) = undefined

instance Monad m => Monad (Stream m) where
    return = pure
    (>>=) = undefined

------------------------------------------------------------------------------
-- Alternative & MonadPlus
------------------------------------------------------------------------------

-- | `empty` represents an action that takes non-zero time to complete.  Since
-- all actions take non-zero time, an `Alternative` composition ('<|>') is a
-- monoidal composition executing all actions in parallel, it is similar to
-- '<>' except that it runs all the actions in parallel and interleaves their
-- results fairly.
instance MonadAsync m => Alternative (Stream m) where
    empty = mempty
    (<|>) = parAlt

instance MonadAsync m => MonadPlus (Stream m) where
    mzero = empty
    mplus = (<|>)

-------------------------------------------------------------------------------
-- Transformer
-------------------------------------------------------------------------------

instance MonadTrans Stream where
    lift mx = Stream $ \_ _ yld -> mx >>= (\a -> (yld a Nothing))

instance (MonadBase b m, Monad m) => MonadBase b (Stream m) where
    liftBase = liftBaseDefault

------------------------------------------------------------------------------
-- Standard transformer instances
------------------------------------------------------------------------------

instance MonadIO m => MonadIO (Stream m) where
    liftIO = lift . liftIO

instance MonadThrow m => MonadThrow (Stream m) where
    throwM = lift . throwM

-- XXX handle and test cross thread state transfer
instance MonadError e m => MonadError e (Stream m) where
    throwError     = lift . throwError
    catchError m h = Stream $ \st stp yld ->
        let handle r = r `catchError` \e -> (runStream (h e)) st stp yld
            yield a Nothing = yld a Nothing
            yield a (Just r) = yld a (Just (catchError r h))
        in handle $ (runStream m) st stp yield

instance MonadReader r m => MonadReader r (Stream m) where
    ask = lift ask
    local f m = Stream $ \st stp yld ->
        let yield a Nothing  = local f $ yld a Nothing
            yield a (Just r) = local f $ yld a (Just (local f r))
        in (runStream m) st (local f stp) yield

instance MonadState s m => MonadState s (Stream m) where
    get     = lift get
    put x   = lift (put x)
    state k = lift (state k)
