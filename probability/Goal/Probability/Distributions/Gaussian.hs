{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fplugin=GHC.TypeLits.KnownNat.Solver -fplugin=GHC.TypeLits.Normalise -fconstraint-solver-iterations=10 #-}

{- | Various instances of statistical manifolds, with a focus on exponential
families. In the documentation we use \(X\) to indicate a random variable
with the distribution being documented.
-}
module Goal.Probability.Distributions.Gaussian (
    -- * Manifolds
    StandardNormal,
    CovarianceMatrix,
    KnownCovariance,
    MultivariateNormal,
    Normal,
    FullNormal,
    DiagonalNormal,
    IsotropicNormal,

    -- * Construction
    splitMultivariateNormal,
    joinMultivariateNormal,
    standardNormal,

    -- * Analysis
    bivariateNormalConfidenceEllipse,
    multivariateNormalCorrelations,
) where

--- Imports ---

--- Goal

import Goal.Core
import Goal.Probability.Distributions
import Goal.Probability.ExponentialFamily
import Goal.Probability.Statistical

import Goal.Geometry

import Goal.Core.Vector.Storable qualified as S
import Goal.Core.Vector.Storable.Linear qualified as L

import System.Random.MWC.Distributions qualified as R

--- Misc

import Control.Monad (replicateM)
import Data.Proxy (Proxy (..))

-- Normal Distribution --

{- | The Mean of a normal distribution. When used as a distribution itself, it
is a Normal distribution with unit variance.
-}
data StandardNormal (n :: Nat)

-- | The variance of a normal distribution.
type CovarianceMatrix t n = Linear t (StandardNormal n) (StandardNormal n)

-- | Synonym for known positive definite covariance matrices.
type KnownCovariance t n = KnownLinear t (StandardNormal n) (StandardNormal n)

--- Multivariate Normal ---

{- | The 'Manifold' of 'MultivariateNormal' distributions. The 'Source'
coordinates are the (vector) mean and the covariance matrix. For the
coordinates of a multivariate normal distribution, the elements of the mean
come first, and then the elements of the covariance matrix in row major
order.

Note that we only store the lower triangular elements of the covariance
matrix, to better reflect the true dimension of a MultivariateNormal
Manifold. In short, be careful when using 'join' and 'split' to access the
values of the Covariance matrix, and consider using the specific instances
for MVNs.
-}
type MultivariateNormal t (n :: Nat) = LocationShape (StandardNormal n) (CovarianceMatrix t n)

type Normal = MultivariateNormal L.PositiveDefinite 1
type FullNormal n = MultivariateNormal L.PositiveDefinite n
type DiagonalNormal n = MultivariateNormal L.Diagonal n
type IsotropicNormal n = MultivariateNormal L.Scale n

{- | Linear models are linear functions with additive Guassian noise.
type SimpleLinearModel = Affine Tensor NormalMean Normal NormalMean
-}

{- | Linear models are linear functions with additive Guassian noise.
type LinearModel f n k = Affine Tensor (MVNMean n) (MultivariateNormal f n) (MVNMean k)
type FullLinearModel n k = LinearModel MVNCovariance n k
type FactorAnalysis n k = Affine Tensor (MVNMean n) (DiagonalNormal n) (MVNMean k)
type PrincipleComponentAnalysis n k = Affine Tensor (MVNMean n) (IsotropicNormal n) (MVNMean k)
-}

-- | Halve the off diagonal elements of a triangular matrix.
preCorrect :: (KnownNat n) => S.Vector n Double -> S.Vector n Double
preCorrect trng = S.triangularMapDiagonal (* 2) $ trng / 2

-- | Double the off diagonal elements of a triangular matrix.
postCorrect :: (KnownNat n) => S.Vector n Double -> S.Vector n Double
postCorrect trng = S.triangularMapDiagonal (/ 2) $ trng * 2

-- | Inversion for general linear operators.
precisionPreCorrection0 :: forall t n. (KnownNat n) => L.Linear t n n -> L.Linear t n n
{-# INLINE precisionPreCorrection0 #-}
precisionPreCorrection0 f@(L.PositiveDefiniteLinear _) =
    L.PositiveDefiniteLinear . preCorrect $ L.toVector f
precisionPreCorrection0 m = m

-- | Inversion for general linear operators.
precisionPostCorrection0 :: forall t n. (KnownNat n) => L.Linear t n n -> L.Linear t n n
{-# INLINE precisionPostCorrection0 #-}
precisionPostCorrection0 f@(L.PositiveDefiniteLinear _) =
    L.PositiveDefiniteLinear . postCorrect $ L.toVector f
precisionPostCorrection0 m = m

precisionPreCorrection ::
    (KnownCovariance t n) =>
    Natural # CovarianceMatrix t n ->
    Natural # CovarianceMatrix t n
precisionPreCorrection = Point . L.toVector . precisionPreCorrection0 . useLinear

precisionPostCorrection ::
    (KnownCovariance t n) =>
    Natural # CovarianceMatrix t n ->
    Natural # CovarianceMatrix t n
precisionPostCorrection = Point . L.toVector . precisionPostCorrection0 . useLinear

splitMultivariateNormal ::
    (KnownCovariance t n) =>
    Natural # MultivariateNormal t n ->
    (Natural # StandardNormal n, Natural # CovarianceMatrix t n)
splitMultivariateNormal mvn =
    let (mu, sgma) = split mvn
     in (mu, precisionPreCorrection sgma)

joinMultivariateNormal ::
    (KnownCovariance t n) =>
    Natural # StandardNormal n ->
    Natural # CovarianceMatrix t n ->
    Natural # MultivariateNormal t n
joinMultivariateNormal mu sgma =
    join mu $ precisionPostCorrection sgma

bivariateNormalConfidenceEllipse ::
    ( KnownCovariance L.PositiveDefinite 2
    , KnownCovariance t 2
    ) =>
    Int ->
    Double ->
    Source # MultivariateNormal t 2 ->
    [(Double, Double)]
bivariateNormalConfidenceEllipse nstps prcnt mvn =
    let (mu, sgma) = split mvn
        pd :: Source # CovarianceMatrix L.PositiveDefinite 2
        pd = fromTensor $ toTensor sgma
        mrt = prcnt .> choleskyDecomposition pd
        xs = range 0 (2 * pi) nstps
        sxs = [fromTuple (cos x, sin x) | x <- xs]
     in S.toPair . coordinates . (mu +) <$> mrt >$> sxs

-- | Create a standard normal distribution in a variety of forms
standardNormal ::
    forall c t n.
    (KnownCovariance t n, Transition Source c (MultivariateNormal t n)) =>
    c # MultivariateNormal t n
standardNormal =
    let sgm0 :: Source # CovarianceMatrix t n
        sgm0 = identity
     in transition $ join 0 sgm0

-- | Computes the correlation matrix of a 'MultivariateNormal' distribution.
multivariateNormalCorrelations ::
    forall t n.
    (KnownCovariance t n) =>
    Source # MultivariateNormal t n ->
    Source # Tensor (StandardNormal n) (StandardNormal n)
multivariateNormalCorrelations mvn =
    let cvrs = toTensor . snd $ split mvn
        diag :: Source # Diagonal (StandardNormal n)
        diag = fromTensor cvrs
        sds = breakManifold $ sqrt diag
        sdmtx = sds >.< sds
     in cvrs / sdmtx

standardNormalLogBaseMeasure ::
    forall n.
    (KnownNat n) =>
    Proxy (StandardNormal n) ->
    S.Vector n Double ->
    Double
standardNormalLogBaseMeasure _ _ =
    let n = natValInt (Proxy :: Proxy n)
     in -fromIntegral n / 2 * log (2 * pi)

multivariateNormalLogBaseMeasure ::
    forall f n.
    (KnownNat n) =>
    Proxy (MultivariateNormal f n) ->
    S.Vector n Double ->
    Double
multivariateNormalLogBaseMeasure _ _ =
    let n = natValInt (Proxy :: Proxy n)
     in -fromIntegral n / 2 * log (2 * pi)

{- | samples a multivariateNormal by way of a covariance matrix i.e. by taking
the square root.
-}
sampleFullNormal ::
    (KnownCovariance L.PositiveDefinite n) =>
    Int ->
    Source # FullNormal n ->
    Random [S.Vector n Double]
sampleFullNormal n p = do
    let (mu, sgma) = split p
        rtsgma = choleskyDecomposition sgma
    x0s <- replicateM n . S.replicateM $ Random (R.normal 0 1)
    return $ coordinates . (mu +) <$> rtsgma >$> (Point <$> x0s)

sampleDiagonalNormal ::
    (KnownCovariance L.Diagonal n) =>
    Int ->
    Source # DiagonalNormal n ->
    Random [S.Vector n Double]
sampleDiagonalNormal n p = do
    let (mu, sgma) = split p
        rtsgma = sqrt sgma
    x0s <- replicateM n . S.replicateM $ Random (R.normal 0 1)
    return $ coordinates . (mu +) <$> rtsgma >$> (Point <$> x0s)

sampleScaleNormal ::
    (KnownCovariance L.Scale n) =>
    Int ->
    Source # IsotropicNormal n ->
    Random [S.Vector n Double]
sampleScaleNormal n p = do
    let (mu, sgma) = split p
        rtsgma = sqrt sgma
    x0s <- replicateM n . S.replicateM $ Random (R.normal 0 1)
    return $ coordinates . (mu +) <$> rtsgma >$> (Point <$> x0s)

--- Internal ---

--- Instances ---

--- Standard Normal ---

type instance PotentialCoordinates (StandardNormal n) = Natural

instance (KnownNat n) => Manifold (StandardNormal n) where
    type Dimension (StandardNormal n) = n

instance (KnownNat n) => Statistical (StandardNormal n) where
    type SamplePoint (StandardNormal n) = S.Vector n Double

instance (KnownNat n) => ExponentialFamily (StandardNormal n) where
    sufficientStatistic = Point
    logBaseMeasure = standardNormalLogBaseMeasure

instance Transition Natural Mean (StandardNormal n) where
    transition = breakChart

instance (KnownNat n) => Legendre (StandardNormal n) where
    potential p = 0.5 * (p <.> toMean p)

instance
    ( ExponentialFamily (StandardNormal n)
    , Transition Natural Mean (StandardNormal n)
    , Legendre (StandardNormal n)
    ) =>
    LogLikelihood Natural (StandardNormal n) (S.Vector n Double)
    where
    logLikelihood = exponentialFamilyLogLikelihood
    logLikelihoodDifferential = exponentialFamilyLogLikelihoodDifferential

--- MultivariateNormal ---

--- Transition Functions

type instance PotentialCoordinates (MultivariateNormal t n) = Natural

instance
    (KnownCovariance t n) =>
    Transition Source Natural (MultivariateNormal t n)
    where
    transition p =
        let (mu, sgma) = split p
            invsgma = inverse sgma
         in joinMultivariateNormal (breakChart $ invsgma >.> mu) . breakChart $ (-2) /> invsgma

instance
    (KnownCovariance t n) =>
    Transition Natural Source (MultivariateNormal t n)
    where
    transition p =
        let (nmu, nsgma) = splitMultivariateNormal p
            insgma = inverse $ (-2) .> nsgma
         in join (breakChart $ insgma >.> nmu) $ breakChart insgma

instance
    (KnownCovariance t n) =>
    Transition Source Mean (MultivariateNormal t n)
    where
    transition mvn =
        let (mu, sgma) = split mvn
            mmvn = join mu $ sgma + (mu >.< mu)
         in breakChart mmvn

instance
    (KnownCovariance t n) =>
    Transition Mean Source (MultivariateNormal t n)
    where
    transition mmvn =
        let (mu, msgma) = split mmvn
            mvn = join mu $ msgma - (mu >.< mu)
         in breakChart mvn

instance
    ( KnownCovariance t n
    , Transition Source Mean (MultivariateNormal t n)
    ) =>
    Transition Natural Mean (MultivariateNormal t n)
    where
    transition = toMean . toSource

instance
    ( KnownCovariance t n
    , Transition Mean Source (MultivariateNormal t n)
    ) =>
    Transition Mean Natural (MultivariateNormal t n)
    where
    transition = toNatural . toSource

--- Basic Instances

instance
    (KnownCovariance t n) =>
    AbsolutelyContinuous Source (MultivariateNormal t n)
    where
    densities mvn xs =
        let (mu, sgma) = split mvn
            n = fromIntegral $ natValInt (Proxy @n)
            scl = (2 * pi) ** (-n / 2) * determinant sgma ** (-1 / 2)
            dffs = [Point $ x - coordinates mu | x <- xs]
            expvals = zipWith (<.>) dffs $ inverse sgma >$> dffs
         in (scl *) . exp . negate . (/ 2) <$> expvals

instance
    (KnownCovariance L.Scale n, Transition c Source (IsotropicNormal n)) =>
    Generative c (IsotropicNormal n)
    where
    sample n = sampleScaleNormal n . toSource

instance
    (KnownCovariance L.Diagonal n, Transition c Source (DiagonalNormal n)) =>
    Generative c (DiagonalNormal n)
    where
    sample n = sampleDiagonalNormal n . toSource

instance
    (KnownCovariance L.PositiveDefinite n, Transition c Source (FullNormal n)) =>
    Generative c (FullNormal n)
    where
    sample n = sampleFullNormal n . toSource

--- Exponential Family Instances

instance
    (KnownCovariance t n) =>
    ExponentialFamily (MultivariateNormal t n)
    where
    sufficientStatistic x =
        let mx = sufficientStatistic x
         in join mx $ mx >.< mx
    averageSufficientStatistic xs =
        let mxs = sufficientStatistic <$> xs
         in join (average mxs) $ mxs >$< mxs
    logBaseMeasure = multivariateNormalLogBaseMeasure

instance (KnownCovariance t n) => Legendre (MultivariateNormal t n) where
    potential p =
        let (nmu, nsgma) = splitMultivariateNormal p
            (insgma, lndt, _) = inverseLogDeterminant . negate $ 2 * nsgma
         in 0.5 * (nmu <.> (insgma >.> nmu)) - 0.5 * lndt

instance
    ( KnownCovariance t n
    , Transition Mean Source (MultivariateNormal t n)
    ) =>
    DuallyFlat (MultivariateNormal t n)
    where
    dualPotential p =
        let sgma = snd . split $ toSource p
            n = natValInt (Proxy @n)
            lndet0 = log $ determinant sgma
            lndet = fromIntegral n * log (2 * pi * exp 1) + lndet0
         in -0.5 * lndet

instance
    ( ExponentialFamily (MultivariateNormal t n)
    , Transition Natural Mean (MultivariateNormal t n)
    , Legendre (MultivariateNormal t n)
    ) =>
    LogLikelihood Natural (MultivariateNormal t n) (S.Vector n Double)
    where
    logLikelihood = exponentialFamilyLogLikelihood
    logLikelihoodDifferential = exponentialFamilyLogLikelihoodDifferential

instance
    ( ExponentialFamily (MultivariateNormal t n)
    , Transition Natural Mean (MultivariateNormal t n)
    , Legendre (MultivariateNormal t n)
    ) =>
    AbsolutelyContinuous Natural (MultivariateNormal t n)
    where
    logDensities = exponentialFamilyLogDensities

instance
    ( ExponentialFamily (MultivariateNormal t n)
    , Transition Mean c (MultivariateNormal t n)
    ) =>
    MaximumLikelihood c (MultivariateNormal t n)
    where
    mle = transition . averageSufficientStatistic

-- --- Exponential Family Instances
--
-- instance (KnownNat n) => ExponentialFamily (FullNormal n) where
--     sufficientStatistic x =
--         let mx = sufficientStatistic x
--          in join mx $ mx >.< mx
--     averageSufficientStatistic xs =
--         let mxs = sufficientStatistic <$> xs
--          in join (average mxs) $ mxs >$< mxs
--     logBaseMeasure = multivariateNormalLogBaseMeasure
--
-- instance (KnownNat n) => ExponentialFamily (DiagonalNormal n) where
--     sufficientStatistic x =
--         let mx = sufficientStatistic x
--          in join mx $ mx >.< mx
--     averageSufficientStatistic xs =
--         let mxs = sufficientStatistic <$> xs
--          in join (average mxs) $ mxs >$< mxs
--     logBaseMeasure = multivariateNormalLogBaseMeasure
--
-- instance (KnownNat n) => ExponentialFamily (IsotropicNormal n) where
--     sufficientStatistic x =
--          join (Point x) . singleton $ S.dotProduct x x
--     averageSufficientStatistic xs =
--          join (Point $ average xs) . singleton . average $ zipWith S.dotProduct xs xs
--     logBaseMeasure = multivariateNormalLogBaseMeasure
--
-- instance (KnownNat n) => Legendre (MultivariateNormal f n) where
--     potential p =
--         let (nmu,nsgma) = split p
--             (insgma,lndt,_) = inverseLogDeterminant . negate $ 2 * nsgma
--          in 0.5 * (nmu <.> (insgma >.> nmu)) -0.5 * lndt
--
-- instance ( KnownNat n , Transition Mean Source (MultivariateNormal f n), Legendre (MultivariateNormal f n) )
--   => DuallyFlat (MultivariateNormal f n) where
--     dualPotential p =
--         let sgma = snd . split $ toSource p
--             n = natValInt (Proxy @n)
--             (_,lndet0,_) = inverseLogDeterminant sgma
--             lndet = fromIntegral n*log (2*pi*exp 1) + lndet0
--          in -0.5 * lndet
--
-- instance ( KnownNat n, ExponentialFamily (MultivariateNormal f n)
--          , Transition Natural Mean (MultivariateNormal f n), Legendre (MultivariateNormal f n) )
--   => LogLikelihood Natural (MultivariateNormal f n) (S.Vector n Double) where
--     logLikelihood = exponentialFamilyLogLikelihood
--     logLikelihoodDifferential = exponentialFamilyLogLikelihoodDifferential
--
-- instance ( KnownNat n, ExponentialFamily (MultivariateNormal f n)
--          , Transition Natural Mean (MultivariateNormal f n), Legendre (MultivariateNormal f n) )
--   => AbsolutelyContinuous Natural (MultivariateNormal f n) where
--     logDensities = exponentialFamilyLogDensities
--
-- instance (KnownNat n, ExponentialFamily (MultivariateNormal f n)
--          , Transition Mean c (MultivariateNormal f n) )
--   => MaximumLikelihood c (MultivariateNormal f n) where
--     mle = transition . averageSufficientStatistic
--
--

--- MVNMean ---

--- MVNCovariance ---

-- instance (Manifold x, KnownNat (Triangular (Dimension x))) => Manifold (MVNCovariance x x) where
--     type Dimension (MVNCovariance x x) = Triangular (Dimension x)

-- instance Manifold x => Map Natural MVNCovariance x x where
--     {-# INLINE (>.>) #-}
--     (>.>) pq x = toTensor pq >.> x
--     {-# INLINE (>$>) #-}
--     (>$>) pq xs = toTensor pq >$> xs
--
-- instance Manifold x => Map Mean MVNCovariance x x where
--     {-# INLINE (>.>) #-}
--     (>.>) pq x = toTensor pq >.> x
--     {-# INLINE (>$>) #-}
--     (>$>) pq xs = toTensor pq >$> xs
--
-- instance Manifold x => Map Source MVNCovariance x x where
--     {-# INLINE (>.>) #-}
--     (>.>) pq x = toTensor pq >.> x
--     {-# INLINE (>$>) #-}
--     (>$>) pq xs = toTensor pq >$> xs
--
-- instance Manifold x => Bilinear Source MVNCovariance x x where
--     {-# INLINE transpose #-}
--     transpose = id
--     {-# INLINE toTensor #-}
--     toTensor = toTensor . toSymmetric
--     {-# INLINE fromTensor #-}
--     fromTensor = fromSymmetric . fromTensor
--
-- instance Manifold x => Bilinear Mean MVNCovariance x x where
--     {-# INLINE transpose #-}
--     transpose = id
--     {-# INLINE toTensor #-}
--     toTensor = toTensor . toSymmetric
--     {-# INLINE fromTensor #-}
--     fromTensor = fromSymmetric . fromTensor
--
-- instance Manifold x => Bilinear Natural MVNCovariance x x where
--     {-# INLINE transpose #-}
--     transpose = id
--     {-# INLINE toTensor #-}
--     toTensor = naturalSymmetricToPrecision . toSymmetric
--     {-# INLINE fromTensor #-}
--     fromTensor = fromSymmetric . naturalPrecisionToSymmetric
--

-- instance KnownNat n => Transition Source Mean (FullNormal n) where
--     transition mvn =
--         let (mu,sgma) = split mvn
--             mmvn :: Source # FullNormal n
--             mmvn = join mu $ sgma + (mu >.< mu)
--          in breakChart mmvn
--
-- instance KnownNat n => Transition Mean Source (FullNormal n) where
--     transition mmvn =
--         let (mu,msgma) = split mmvn
--             mvn :: Mean # FullNormal n
--             mvn = join mu $ msgma - (mu >.< mu)
--          in breakChart mvn
--
-- instance KnownNat n => Transition Source Mean (DiagonalNormal n) where
--     transition mvn =
--         let (mu,sgma) = split mvn
--             mmvn :: Source # DiagonalNormal n
--             mmvn = join mu $ sgma + (mu >.< mu)
--          in breakChart mmvn
--
-- instance KnownNat n => Transition Mean Source (DiagonalNormal n) where
--     transition mmvn =
--         let (mu,msgma) = split mmvn
--             mvn :: Mean # DiagonalNormal n
--             mvn = join mu $ msgma - (mu >.< mu)
--          in breakChart mvn
--
-- instance KnownNat n => Transition Source Mean (IsotropicNormal n) where
--     transition mvn =
--         let (mu,sgma) = split mvn
--             n = fromIntegral . natVal $ Proxy @n
--             mmvn :: Source # IsotropicNormal n
--             mmvn = join mu . (*n) $ sgma + (mu >.< mu)
--          in breakChart mmvn
--
-- instance KnownNat n => Transition Mean Source (IsotropicNormal n) where
--     transition mmvn =
--         let (mu,msgma) = split mmvn
--             n = fromIntegral . natVal $ Proxy @n
--             mvn :: Mean # IsotropicNormal n
--             mvn = join mu $ msgma/n - (mu >.< mu)
--          in breakChart mvn
--
-- --- Linear Models ---
--
-- instance ( KnownNat n, KnownNat k )
--   => Transition Natural Source (LinearModel f n k) where
--       transition nfa =
--           let (nmvn,nmtx) = split nfa
--               smvn = toSource nmvn
--               svr = snd $ split smvn
--               smtx = unsafeMatrixMultiply svr nmtx
--            in join smvn smtx
--
-- instance ( KnownNat n, KnownNat k )
--   => Transition Source Natural (LinearModel f n k) where
--       transition sfa =
--           let (smvn,smtx) = split sfa
--               nmvn = toNatural smvn
--               nvr = snd $ split nmvn
--               nmtx = -2 .> unsafeMatrixMultiply nvr smtx
--            in join nmvn nmtx
--
--
-- --- Graveyard ---
--
--
-- --instance ( KnownNat n, KnownNat k)
-- --  => Transition Source Natural (PrincipleComponentAnalysis n k) where
-- --      transition spca =
-- --          let (iso,cwmtx) = split spca
-- --              (cmu,cvr) = split iso
-- --              invsg = recip . S.head $ coordinates cvr
-- --              thtmu = Point $ realToFrac invsg * coordinates cmu
-- --              thtsg = singleton $ (-0.5) * invsg
-- --              imtx = fromMatrix $ realToFrac invsg * toMatrix cwmtx
-- --           in join (join thtmu thtsg) imtx
--
--
-- --instance KnownNat n => Legendre (FullNormal n) where
-- --    potential p =
-- --        let (nmu,nsgma) = split p
-- --            (insgma,lndt,_) = inverseLogDeterminant . negate $ 2 * (toTensor nsgma)
-- --         in 0.5 * (nmu <.> (insgma >.> nmu)) -0.5 * lndt
--
-- --instance KnownNat n => Legendre (DiagonalNormal n) where
-- --    potential p =
-- --        let (nmu,nsgma) = split p
-- --            (insgma,lndt,_) = inverseLogDeterminant . negate $ 2 * nsgma
-- --         in 0.5 * (nmu <.> (insgma >.> nmu)) -0.5 * lndt
-- --
-- --instance ( KnownNat n, KnownNat k)
-- --  => Transition Natural Source (Affine Tensor (MVNMean n) (MultivariateNormal n) (MVNMean k)) where
-- --    transition nfa =
-- --        let (mvn,nmtx) = split nfa
-- --            (nmu,nsg) = splitNaturalMultivariateNormal mvn
-- --            invsg = -2 * nsg
-- --            ssg = S.inverse invsg
-- --            smu = S.matrixVectorMultiply ssg nmu
-- --            smvn = joinMultivariateNormal smu ssg
-- --            smtx = S.matrixMatrixMultiply ssg $ toMatrix nmtx
-- --         in join smvn $ fromMatrix smtx
-- --
-- --instance ( KnownNat n, KnownNat k)
-- --  => Transition Source Natural (Affine Tensor (MVNMean n) (MultivariateNormal n) (MVNMean k)) where
-- --    transition lmdl =
-- --        let (smvn,smtx) = split lmdl
-- --            (smu,ssg) = splitMultivariateNormal smvn
-- --            invsg = S.inverse ssg
-- --            nmu = S.matrixVectorMultiply invsg smu
-- --            nsg = -0.5 * invsg
-- --            nmtx = S.matrixMatrixMultiply invsg $ toMatrix smtx
-- --            nmvn = joinNaturalMultivariateNormal nmu nsg
-- --         in join nmvn $ fromMatrix nmtx
-- --
-- --instance Transition Natural Source (Affine Tensor NormalMean Normal NormalMean) where
-- --      transition nfa =
-- --          let nfa' :: Natural # LinearModel 1 1
-- --              nfa' = breakChart nfa
-- --              sfa' :: Source # LinearModel 1 1
-- --              sfa' = transition nfa'
-- --           in breakChart sfa'
-- --
-- --instance Transition Source Natural (Affine Tensor NormalMean Normal NormalMean) where
-- --      transition sfa =
-- --          let sfa' :: Source # LinearModel 1 1
-- --              sfa' = breakChart sfa
-- --              nfa' :: Natural # LinearModel 1 1
-- --              nfa' = transition sfa'
-- --           in breakChart nfa'
-- --instance KnownNat n => Transition Natural Source (MultivariateNormal f n) where
-- --    transition p =
-- --        let (nmu,nsym) = split p
-- --            nsgma = toTensor nsym
-- --            insgma = (-0.5) .> inverse nsgma
-- --            ssym :: Mean # MVNCovariance (MVNMean n) (MVNMean n)
-- --            ssym = fromTensor insgma
-- --         in join (breakChart $ insgma >.> nmu) $ breakChart ssym
-- --
-- --instance ( KnownNat n, Bilinear Natural f (MVNMean n) (MVNMean n)
-- --         , Square Source f (MVNMean n) (MVNMean n))
-- --         => Transition Source Natural (MultivariateNormal f n) where
-- --    transition p =
-- --        let (mu,sgma) = split p
-- --            invsgma = inverse sgma
-- --            nnrm :: Source # MultivariateNormal f n
-- --            nnrm = join (invsgma >.> mu) $ (-0.5) * invsgma
-- --         in breakChart nnrm
-- --
--
--
--
-- --instance ( KnownNat n, KnownNat k)
-- --  => Transition Natural Source (Affine Tensor (MVNMean n) (Replicated n Normal) (MVNMean k)) where
-- --    transition nfa =
-- --        let (nnrms,nmtx) = split nfa
-- --            (nmu,nsg) = S.toPair . S.toColumns . S.fromRows . S.map coordinates
-- --                $ splitReplicated nnrms
-- --            invsg = -2 * nsg
-- --            ssg = recip invsg
-- --            smu = nmu / invsg
-- --            snrms = joinReplicated $ S.zipWith (curry fromTuple) smu ssg
-- --            smtx = S.matrixMatrixMultiply (S.diagonalMatrix ssg) $ toMatrix nmtx
-- --         in join snrms $ fromMatrix smtx
--
-- --instance ( KnownNat n, KnownNat k)
-- --  => Transition Source Natural (Affine Tensor (MVNMean n) (Replicated n Normal) (MVNMean k)) where
-- --    transition sfa =
-- --        let (snrms,smtx) = split sfa
-- --            (smu,ssg) = S.toPair . S.toColumns . S.fromRows . S.map coordinates
-- --                $ splitReplicated snrms
-- --            invsg = recip ssg
-- --            nmu = invsg * smu
-- --            nsg = -0.5 * invsg
-- --            nmtx = S.matrixMatrixMultiply (S.diagonalMatrix invsg) $ toMatrix smtx
-- --            nnrms = joinReplicated $ S.zipWith (curry fromTuple) nmu nsg
-- --         in join nnrms $ fromMatrix nmtx
--
-- --instance KnownNat n => Transition Source Natural (IsotropicNormal n) where
-- --    transition p =
-- --        let (mu,sgma) = split p
-- --            invsgma = inverse sgma
-- --         in join (breakChart $ invsgma >.> mu) . breakChart $ (-0.5) * invsgma
-- --
-- --instance KnownNat n => Transition Natural Source (IsotropicNormal n) where
-- --    transition p =
-- --        let (nmu,nsgma) = split p
-- --            insgma = (-0.5) .> inverse nsgma
-- --         in join (breakChart $ insgma >.> nmu) $ breakChart insgma
--
-- ---- | Split a MultivariateNormal into its Means and Covariance matrix.
-- --splitMultivariateNormal
-- --    :: KnownNat n
-- --    => Source # MultivariateNormal n
-- --    -> (S.Vector n Double, S.Matrix n n Double)
-- --splitMultivariateNormal mvn =
-- --    let (mu,cvr) = split mvn
-- --     in (coordinates mu, S.fromLowerTriangular $ coordinates cvr)
-- --
-- ---- | Join a covariance matrix into a MultivariateNormal.
-- --joinMultivariateNormal
-- --    :: KnownNat n
-- --    => S.Vector n Double
-- --    -> S.Matrix n n Double
-- --    -> Source # MultivariateNormal n
-- --joinMultivariateNormal mus sgma =
-- --    join (Point mus) (Point $ S.lowerTriangular sgma)
-- --
-- ---- | Split a MultivariateNormal into its Means and Covariance matrix.
-- --splitMeanMultivariateNormal
-- --    :: KnownNat n
-- --    => Mean # MultivariateNormal n
-- --    -> (S.Vector n Double, S.Matrix n n Double)
-- --splitMeanMultivariateNormal mvn =
-- --    let (mu,cvr) = split mvn
-- --     in (coordinates mu, S.fromLowerTriangular $ coordinates cvr)
-- --
-- ---- | Join a covariance matrix into a MultivariateNormal.
-- --joinMeanMultivariateNormal
-- --    :: KnownNat n
-- --    => S.Vector n Double
-- --    -> S.Matrix n n Double
-- --    -> Mean # MultivariateNormal n
-- --joinMeanMultivariateNormal mus sgma =
-- --    join (Point mus) (Point $ S.lowerTriangular sgma)
-- --
--
-- ---- | Split a MultivariateNormal into the precision weighted means and (-0.5*)
-- ---- Precision matrix. Note that this performs an easy to miss computation for
-- ---- converting the natural parameters in our reduced representation of MVNs into
-- ---- the full precision matrix.
-- --splitNaturalMultivariateNormal
-- --    :: KnownNat n
-- --    => Natural # MultivariateNormal n
-- --    -> (S.Vector n Double, S.Matrix n n Double)
-- --splitNaturalMultivariateNormal np =
-- --    let (nmu,cvrs) = split np
-- --        nmu0 = coordinates nmu
-- --        nsgma0' = (/2) . S.fromLowerTriangular $ coordinates cvrs
-- --        nsgma0 = nsgma0' + S.diagonalMatrix (S.takeDiagonal nsgma0')
-- --     in (nmu0, nsgma0)
-- --
-- ---- | Joins a MultivariateNormal out of the precision weighted means and (-0.5)
-- ---- Precision matrix. Note that this performs an easy to miss computation for
-- ---- converting the full precision Matrix into the reduced, EF representation we use here.
-- --joinNaturalMultivariateNormal
-- --    :: KnownNat n
-- --    => S.Vector n Double
-- --    -> S.Matrix n n Double
-- --    -> Natural # MultivariateNormal n
-- --joinNaturalMultivariateNormal nmu0 nsgma0 =
-- --    let nmu = Point nmu0
-- --        diag = S.diagonalMatrix $ S.takeDiagonal nsgma0
-- --     in join nmu . Point . S.lowerTriangular $ 2*nsgma0 - diag
-- --
-- -- | Confidence elipses for bivariate normal distributions.
-- --isotropicNormalToFull
-- --    :: KnownNat n
-- --    => Natural # IsotropicNormal n
-- --    -> Natural # MultivariateNormal n
-- --isotropicNormalToFull iso =
-- --    let (mus,sgma0) = split iso
-- --        sgma = realToFrac . S.head $ coordinates sgma0
-- --     in joinNaturalMultivariateNormal (coordinates mus) $ sgma * S.matrixIdentity
-- --
-- --fullNormalToIsotropic
-- --    :: KnownNat n
-- --    => Mean # MultivariateNormal n
-- --    -> Mean # IsotropicNormal n
-- --fullNormalToIsotropic iso =
-- --    let (mus,sgma0) = splitMeanMultivariateNormal iso
-- --        sgma = S.sum $ S.takeDiagonal sgma0
-- --     in join (Point mus) $ singleton sgma
-- --
-- --diagonalNormalToFull
-- --    :: KnownNat n
-- --    => Natural # DiagonalNormal n
-- --    -> Natural # MultivariateNormal n
-- --diagonalNormalToFull diag =
-- --    let (mus,prcs) = split diag
-- --     in joinNaturalMultivariateNormal (coordinates mus) . S.diagonalMatrix $ coordinates prcs
-- --
-- --fullNormalToDiagonal
-- --    :: KnownNat n
-- --    => Mean # MultivariateNormal n
-- --    -> Mean # DiagonalNormal n
-- --fullNormalToDiagonal diag =
-- --    let (mus,sgma) = splitMeanMultivariateNormal diag
-- --     in join (Point mus) . Point $ S.takeDiagonal sgma
--
-- -- Restricted MVNs --
--
-- -- | The 'Manifold' of 'MultivariateNormal' distributions. The 'Source'
-- -- coordinates are the (vector) mean and the covariance matrix. For the
-- -- coordinates of a multivariate normal distribution, the elements of the mean
-- -- come first, and then the elements of the covariance matrix in row major
-- -- order.
-- --type IsotropicNormal (n :: Nat) = LocationShape (MVNMean n) NormalVariance
-- --
-- --type DiagonalNormal (n :: Nat) = LocationShape (MVNMean n) (Replicated n NormalVariance)
--
-- --instance KnownNat n => Legendre (DiagonalNormal n) where
-- --    potential p =
-- --        let (nmu,nsgma) = split p
-- --            (insgma,lndt,_) = inverseLogDeterminant . negate $ 2 * nsgma
-- --         in 0.5 * (nmu <.> (insgma >.> nmu)) -0.5 * lndt
-- --
-- --instance KnownNat n => Legendre (IsotropicNormal n) where
-- --    potential p =
-- --        let (nmu,nsgma) = split p
-- --            (insgma,lndt,_) = inverseLogDeterminant . negate $ 2 * nsgma
-- --         in 0.5 * (nmu <.> (insgma >.> nmu)) -0.5 * lndt
--
--
