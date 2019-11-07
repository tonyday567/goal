{-# LANGUAGE Arrows #-}
-- | A collection of algorithms for optimizing harmoniums.

module Goal.Probability.ExponentialFamily.Harmonium.Learning
    ( -- * Expectation Maximization
      expectationMaximization
    , expectationMaximizationAscent
    -- * Differentials
    , harmoniumInformationProjectionDifferential
    , contrastiveDivergence
      -- ** Conditional
    , conditionalExpectationMaximizationAscent
    , conditionalHarmoniumConjugationDifferential
    ) where


--- Imports ---


-- Goal --

import Goal.Core
import Goal.Geometry

import Goal.Probability.Statistical
import Goal.Probability.ExponentialFamily
import Goal.Probability.ExponentialFamily.Harmonium
import Goal.Probability.ExponentialFamily.Harmonium.Conditional
import Goal.Probability.ExponentialFamily.Harmonium.Inference

import qualified Data.Vector as V
import System.Random.MWC.Probability hiding (initialize,sample)
import System.Random.MWC.Distributions (uniformShuffle)



--- Differentials ---


-- | The differential of the dual relative entropy. Minimizing this results in
-- the information projection of the model against the marginal distribution of
-- the given harmonium. This is more efficient than the generic version.
harmoniumInformationProjectionDifferential
    :: ( Map Mean Natural f z x, LegendreExponentialFamily z
       , ExponentialFamily x, Generative Natural x)
    => Int
    -> Natural # Harmonium z f x -- ^ Harmonium
    -> Natural # x -- ^ Model Distribution
    -> Random r (Mean # x) -- ^ Differential Estimate
{-# INLINE harmoniumInformationProjectionDifferential #-}
harmoniumInformationProjectionDifferential n hrm px = do
    xs <- sample n px
    let (affmn,nm0) = splitBottomHarmonium hrm
        (nn,nmn) = splitAffine affmn
        nm = fromOneHarmonium nm0
        mxs = sufficientStatistic <$> xs
        mys0 = nmn >$> mxs
        mys = zipWith (\mx my0 -> mx <.> (px - nm) - potential (nn + my0)) mxs mys0
        ln = fromIntegral $ length xs
        mxht = average mxs
        myht = sum mys / ln
        foldfun (mx,my) (k,z0) = (k+1,z0 + ((my - myht) .> (mx - mxht)))
    return . uncurry (/>) . foldr foldfun (-1,0) $ zip mxs mys

-- | Contrastive divergence on harmoniums (<https://www.mitpressjournals.org/doi/abs/10.1162/089976602760128018?casa_token=x_Twj1HaXcMAAAAA:7-Oq181aubCFwpG-f8Lo1wRKvGnmujzl8zjn9XbeO5nGhfvKCCQjsu4K4pJCkMNYUYWqc2qG7TRXBg Hinton, 2019>).
contrastiveDivergence
    :: ( Generative Natural z, ExponentialFamily z, Generative Natural x
       , ExponentialFamily x, Bilinear f z x, Map Mean Natural f x z, Map Mean Natural f z x )
      => Int -- ^ The number of contrastive divergence steps
      -> Sample z -- ^ The initial states of the Gibbs chains
      -> Natural # Harmonium z f x -- ^ The harmonium
      -> Random s (Mean # Harmonium z f x) -- ^ The gradient estimate
contrastiveDivergence cdn zs hrm = do
    xzs0 <- initialPass hrm zs
    xzs1 <- iterateM' cdn (gibbsPass hrm) xzs0
    return $ stochasticRelativeEntropyDifferential xzs0 xzs1


--- Expectation Maximization ---


-- | EM implementation for harmoniums (and by extension mixture models).
expectationMaximization
    :: ( DuallyFlatExponentialFamily (Harmonium z f x), LegendreExponentialFamily x
       , ExponentialFamily z, Bilinear f z x, Map Mean Natural f x z )
    => Sample z -- ^ Observations
    -> Natural # Harmonium z f x -- ^ Current Harmonium
    -> Natural # Harmonium z f x -- ^ Updated Harmonium
{-# INLINE expectationMaximization #-}
expectationMaximization zs hrm = transition $ harmoniumExpectationStep zs hrm

-- | Ascent of the EM objective on harmoniums for when the expectation
-- step can't be computed in closed-form. The convergent harmonium distribution
-- of the output harmonium-list is the result of 1 iteration of the EM
-- algorithm.
expectationMaximizationAscent
    :: ( LegendreExponentialFamily (Harmonium z f x), LegendreExponentialFamily x
       , ExponentialFamily z, Bilinear f z x, Map Mean Natural f x z )
    => Double
    -> GradientPursuit
    -> Sample z -- ^ Observations
    -> Natural # Harmonium z f x -- ^ Current Harmonium
    -> [Natural # Harmonium z f x] -- ^ Updated Harmonium
{-# INLINE expectationMaximizationAscent #-}
expectationMaximizationAscent eps gp zs nhrm =
    let mhrm' = harmoniumExpectationStep zs nhrm
     in vanillaGradientSequence (relativeEntropyDifferential mhrm') (-eps) gp nhrm

-- | Ascent of the conditional EM objective on conditional harmoniums, which
-- allows conditional harmoniums to be fit by approximate EM.
conditionalExpectationMaximizationAscent
    :: ( Propagate Mean Natural f (y,x) z, Bilinear g y x, Map Mean Natural g x y
       , LegendreExponentialFamily (Harmonium y g x), LegendreExponentialFamily x
       , ExponentialFamily y, ExponentialFamily z )
    => Double -- ^ Learning rate
    -> GradientPursuit -- ^ Gradient pursuit algorithm
    -> Int -- ^ Minibatch size
    -> Int -- ^ Number of iterations
    -> Sample (y,z) -- ^ (Output,Input) samples
    -> Natural #> ConditionalHarmonium f y g x z
    -> Random r (Natural #> ConditionalHarmonium f y g x z)
{-# INLINE conditionalExpectationMaximizationAscent #-}
conditionalExpectationMaximizationAscent eps gp nbtch nstps yzs0 chrm0 = do
    let chrmcrc = loopCircuit' chrm0 $ proc (mhrmzs,chrm) -> do
            let (mhrms,zs) = unzip mhrmzs
                dhrms = zipWith (-) mhrms $ transition <$> hrmhts
                (dchrm,hrmhts) = propagate dhrms zs chrm
            gradientCircuit eps gp -< (chrm,vanillaGradient dchrm)
    let zs0 = snd <$> yzs0
        mhrms0 = conditionalHarmoniumExpectationStep yzs0 chrm0
        ncycs = 1 + div (length yzs0 - 1) (nstps * nbtch)
    mhrmzs0 <- replicateM ncycs (shuffleList . zip mhrms0 $ sufficientStatistic <$> zs0)
    let mhrmzss = take nstps . breakEvery nbtch $ concat mhrmzs0
    iterateCircuit chrmcrc mhrmzss

-- | An approximate differntial for conjugating a harmonium likelihood.
conditionalHarmoniumConjugationDifferential
    :: ( Propagate Mean Natural f (y,x) z, Manifold (g y x), LegendreExponentialFamily (Harmonium y g x)
       , LegendreExponentialFamily x, ExponentialFamily y, ExponentialFamily z )
    => Double -- ^ Conjugation shift
    -> Natural # z -- ^ Conjugation parameters
    -> Sample z -- ^ Sample points
    -> Natural #> ConditionalHarmonium f y g x z
    -> Mean #> ConditionalHarmonium f y g x z
{-# INLINE conditionalHarmoniumConjugationDifferential #-}
conditionalHarmoniumConjugationDifferential rho0 rprms xsmps chrm =
    let rcts = conjugationCurve rho0 rprms xsmps
        mhrms = transition <$> nhrms
        ptns = potential <$> nhrms
        dhrms = [ (ptn - rct) .> mhrm | (rct,mhrm,ptn) <- zip3 rcts mhrms ptns ]
        (dchrm,nhrms) = propagate dhrms (sufficientStatistic <$> xsmps) chrm
     in dchrm

shuffleList :: [a] -> Random r [a]
shuffleList xs = fmap V.toList . Prob $ uniformShuffle (V.fromList xs)

---- | Estimates the stochastic cross entropy differential of a conjugated harmonium with
---- respect to the relative entropy, and given an observation.
--stochasticConjugatedHarmoniumDifferential
--    :: ( Map Mean Natural f z x, Bilinear f z x, ExponentialFamily z
--       , ExponentialFamily x, Generative Natural z, Generative Natural x )
--       => Sample z -- ^ Observations
--       -> Natural # x -- ^ Conjugation Parameters
--       -> Natural # Harmonium f z x -- ^ Harmonium
--       -> Random s (CotangentVector Natural (Harmonium f z x)) -- ^ Differential
--{-# INLINE stochasticConjugatedHarmoniumDifferential #-}
--stochasticConjugatedHarmoniumDifferential zs rprms hrm = do
--    pzxs <- initialPass hrm zs
--    qzxs <- sampleConjugatedHarmonium (length zs) (toSingletonSum rprms) hrm
--    return $ stochasticCrossEntropyDifferential' pzxs qzxs
--
---- | The stochastic conditional cross-entropy differential, based on target
---- inputs and outputs expressed as distributions in mean coordinates.
--mixtureStochasticConditionalCrossEntropyDifferential
--    :: ( ExponentialFamily z, ExponentialFamily x, Legendre Natural z, KnownNat k )
--    => Sample x -- ^ Input mean distributions
--    -> Sample z -- ^ Output mean distributions
--    -> Mean #> Natural # MixtureGLM z k x -- ^ Function
--    -> CotangentVector (Mean #> Natural) (MixtureGLM z k x) -- ^ Differential
--{-# INLINE mixtureStochasticConditionalCrossEntropyDifferential #-}
--mixtureStochasticConditionalCrossEntropyDifferential xs zs mglm =
--    -- This could be better optimized but not throwing out the second result of propagate
--    let dmglms = dualIsomorphism
--            <$> zipWith stochasticMixtureDifferential ((:[]) <$> zs) (mglm >$>* xs)
--        dzs = [ fst . splitAffine . fst $ splitBottomHarmonium dmglm | dmglm <- dmglms ]
--        f = snd $ splitBottomSubLinear mglm
--        df = fst $ propagate dzs (sufficientStatistic <$> xs) f
--     in primalIsomorphism $ joinBottomSubLinear (averagePoint dmglms) df
--
--
--
----dualContrastiveDivergence
----    :: forall s f z x
----    . ( Generative Natural z, ExponentialFamily z, ExponentialFamily x, Generative Natural x
----      , Map Mean Natural f x z, Bilinear f z x, Bilinear f x z )
----      => Int -- ^ The number of contrastive divergence steps
----      -> Int -- ^ The number of samples
----      -> Natural # x -- ^ Target marginal
----      -> Natural # Harmonium f z x -- ^ The harmonium
----      -> Random s (CotangentVector Natural (Harmonium f z x)) -- ^ The gradient estimate
----dualContrastiveDivergence cdn nsmps prr hrm = do
----    xs <- sample nsmps prr
----    dhrm' <- contrastiveDivergence cdn xs $ transposeHarmonium hrm
----    return $ primalIsomorphism . transposeHarmonium $ dualIsomorphism dhrm'
----
------class FitConjugationParameters (fs :: [* -> * -> *]) (ms :: [*]) where
------    fitConjugationParameters
------        :: Double
------        -> Maybe Int
------        -> Natural # DeepHarmonium fs ms
------        -> Natural # Sum (Tail ms)
------        -> Random s (Natural # Sum (Tail ms))
------
------instance FitConjugationParameters '[] '[m] where
------    {-# INLINE fitConjugationParameters #-}
------    fitConjugationParameters _ _ _ _ = zero
------
------instance ( Manifold (DeepHarmonium fs (n : ms)), Map Mean Natural f z x, Manifold (Sum ms)
------         , ExponentialFamily n, SampleConjugated fs (n : ms), Generative Natural m
------         , Dimension n <= Dimension (DeepHarmonium fs (n : ms)) )
------  => SampleConjugated (f : fs) (m : n : ms) where
------    {-# INLINE sampleConjugated #-}
------    sampleConjugated rprms dhrm = do
------        let (pn,pf,dhrm') = splitBottomHarmonium dhrm
------            (rprm,rprms') = splitSum rprms
------        (ys,xs) <- fmap hUnzip . sampleConjugated rprms' $ biasBottom rprm dhrm'
------        zs <- samplePoint $ mapReplicatedPoint (pn +) (pf >$>* ys)
------        return . hZip zs $ hZip ys xs
------
------
