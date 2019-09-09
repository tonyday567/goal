{-# LANGUAGE Arrows,LambdaCase #-}
-- | A set of functions for working with the 'Arrow' known as a Mealy automata,
-- here referred to as 'Circuit's. Circuits are essentialy a way of building
-- composable fold and iterator operations, where some of the values being
-- processed can be hidden.
module Goal.Core.Circuit
    ( -- * Circuits
    Circuit (Circuit)
    , accumulateFunction
    , accumulateCircuit
    , streamCircuit
    , iterateCircuit
    , loopCircuit
    , loopCircuit'
    , arrM
    -- * Chains
    , Chain
    , chain
    , chainCircuit
    , streamChain
    , iterateChain
    -- ** Recursive Computations
    , iterateM
    , iterateM'
    ) where

--- Imports ---


-- Unqualified --

import Control.Arrow
import Control.Monad

-- Qualified --

import qualified Control.Category as C

--- Circuits ---

-- | An arrow which takes an input, monadically produces an output, and updates
-- an (inaccessable) internal state.
newtype Circuit m a b = Circuit (a -> m (b, Circuit m a b))

-- | Takes a function from a value and an accumulator (e.g. just a sum value or
-- an evolving set of parameters for some model) to a value and an accumulator.
-- The accumulator is then looped back into the function, returning a Circuit
-- from a to b, which updates the accumulator every step.
accumulateFunction :: Monad m => acc -> (a -> acc -> m (b,acc)) -> Circuit m a b
{-# INLINE accumulateFunction #-}
accumulateFunction acc f = Circuit $ \a -> do
    (b,acc') <- f a acc
    return (b,accumulateFunction acc' f)

-- | accumulateCircuit takes a Circuit with an accumulating parameter and loops it.
accumulateCircuit :: Monad m => acc -> Circuit m (a,acc) (b,acc) -> Circuit m a b
{-# INLINE accumulateCircuit #-}
accumulateCircuit acc0 mly0 = accumulateFunction (acc0,mly0) $ \a (acc,Circuit crcf) -> do
    ((b,acc'),mly') <- crcf (a,acc)
    return (b,(acc',mly'))

-- | Takes a Circuit with an accumulating parameter and loops it, but continues
-- to return the output and calculated parameter.
loopCircuit :: Monad m => acc -> Circuit m (a,acc) (b,acc) -> Circuit m a (b,acc)
{-# INLINE loopCircuit #-}
loopCircuit acc0 mly0 = accumulateFunction (acc0,mly0) $ \a (acc,Circuit crcf) -> do
    ((b,acc'),mly') <- crcf (a,acc)
    return ((b,acc'),(acc',mly'))

-- | Takes a Circuit over an accumulator and no output and loops it.
loopCircuit' :: Monad m => acc -> Circuit m (a,acc) acc -> Circuit m a acc
{-# INLINE loopCircuit' #-}
loopCircuit' acc0 mly0 = accumulateFunction (acc0,mly0) $ \a (acc,Circuit crcf) -> do
    (acc',mly') <- crcf (a,acc)
    return (acc',(acc',mly'))


-- | Feeds a list of inputs into a Circuit automata and gathers a list of outputs.
streamCircuit :: Monad m => Circuit m a b -> [a] -> m [b]
{-# INLINE streamCircuit #-}
streamCircuit _ [] = return []
streamCircuit (Circuit mf) (a:as) = do
    (b,crc') <- mf a
    (b :) <$!> streamCircuit crc' as

-- | Feeds a list of inputs into a Circuit automata and returns the final
-- output. Throws an error on the empty list.
iterateCircuit :: Monad m => Circuit m a b -> [a] -> m b
{-# INLINE iterateCircuit #-}
iterateCircuit _ [] = error "Empty list fed to iterateCircuit"
iterateCircuit (Circuit mf) [a] = fst <$> mf a
iterateCircuit (Circuit mf) (a:as) = do
    (_,crc') <- mf a
    iterateCircuit crc' as

-- | Turn a monadic function into a circuit.
arrM :: Monad m => (a -> m b) -> Circuit m a b
arrM mf = Circuit $ \a -> do
    b <- mf a
    return (b, arrM mf)


--- Chains ---


-- | A 'Chain' is a form of iterator built on a 'Circuit'.
type Chain m x = Circuit m () x

-- | Creates a 'Chain' from an initial state and a transition function. The
-- first step of the chain returns the initial state, and then continues with
-- generated states.
chain
    :: Monad m
    => (x -> m x) -- ^ The transition function
    -> x -- ^ The initial state
    -> Chain m x -- ^ The resulting 'Chain'
{-# INLINE chain #-}
chain mf x0 = accumulateFunction x0 $ \() x -> do
    x' <- mf x
    return (x,x')

-- | Creates a 'Chain' from an initial state and a transition circuit. The
-- first step of the chain returns the initial state, and then continues with
-- generated states.
chainCircuit
    :: Monad m
    => x -- ^ The initial state
    -> Circuit m x x -- ^ The transition circuit
    -> Chain m x -- ^ The resulting 'Chain'
{-# INLINE chainCircuit #-}
chainCircuit x0 crc = accumulateCircuit x0 $ proc ((),x) -> do
    x' <- crc -< x
    returnA -< (x,x')

-- | Returns a list of the given size of the given 'Chain's output.
streamChain :: Monad m => Int -> Chain m x -> m [x]
{-# INLINE streamChain #-}
streamChain n chn = streamCircuit chn $ replicate (n+1) ()

-- | Returns the given index of the given 'Chain's output.
iterateChain :: Monad m => Int -> Chain m x -> m x
{-# INLINE iterateChain #-}
iterateChain 0 (Circuit mf) = fst <$> mf ()
iterateChain k (Circuit mf) = mf () >>= iterateChain (k-1) . snd

-- | Iterate a monadic action the given number of times, returning the complete
-- sequence of computations.
iterateM :: Monad m => Int -> (x -> m x) -> x -> m [x]
{-# INLINE iterateM #-}
iterateM n mf x0 = streamChain n $ chain mf x0

-- | Iterate a monadic action the given number of times.
iterateM' :: Monad m => Int -> (x -> m x) -> x -> m x
{-# INLINE iterateM' #-}
iterateM' n mf x0 = iterateChain n $ chain mf x0


--- Instances ---


instance Monad m => C.Category (Circuit m) where
    --id :: Circuit a a
    {-# INLINE id #-}
    id = Circuit $ \a -> return (a,C.id)
    --(.) :: Circuit b c -> Circuit a b -> Circuit a c
    {-# INLINE (.) #-}
    (.) = dot
        where dot (Circuit crc1) (Circuit crc2) = Circuit $ \a -> do
                  (b, crcA2') <- crc2 a
                  (c, crcA1') <- crc1 b
                  return (c, crcA1' `dot` crcA2')

instance Monad m => Arrow (Circuit m) where
    --arr :: (a -> b) -> Circuit a b
    {-# INLINE arr #-}
    arr f = Circuit $ \a -> return (f a, arr f)
    --first :: Circuit a b -> Circuit (a,c) (b,c)
    {-# INLINE first #-}
    first (Circuit crcf) = Circuit $ \(a,c) -> do
        (b, crcA') <- crcf a
        return ((b,c), first crcA')

instance Monad m => ArrowChoice (Circuit m) where
    --left :: Circuit a b -> Circuit (Either a c) (Either b c)
    {-# INLINE left #-}
    left crcA@(Circuit crcf) = Circuit $
        \case
          Left a -> do
              (b,crcA') <- crcf a
              return (Left b,left crcA')
          Right c -> return (Right c,left crcA)
