{-# LANGUAGE TypeOperators,TypeFamilies,FlexibleContexts,DataKinds,Arrows #-}

--- Imports ---


-- Goal --

import Goal.Core
import Goal.Geometry
import Goal.Probability
import Goal.Simulation

import qualified Goal.Core.Vector.Boxed as B

import Goal.Datasets.MNIST


-- Globals ---


-- Network --

ip :: Source # Normal
ip = Point $ B.doubleton 0 0.001

type MLP = Categorical Int 10 <*< Replicated 128 Bernoulli <*< Replicated 256 Bernoulli <* Replicated MNISTSize (MeanNormal (1/1))
--type MLP = Categorical Int 10 <*< Convolutional 20 5 1 MNISTHeight MNISTWidth 1 Bernoulli (MeanNormal (1/1))
-- Data --


-- Training --

type NBatch = 128


nepchs,tbtch :: Int
nepchs = 10
tbtch = 100

eps :: Double
eps = -0.005

-- Momentum
mxmu :: Double
mxmu = 0.9

mu :: Int -> Double
mu = defaultMomentumSchedule mxmu

-- Adam
b1,b2,rg :: Double
b1 = 0.9
b2 = 0.999
rg = 1e-8


-- Functions --

classifications :: KnownNat n => B.Vector n (B.Vector MNISTSize Double) -> Mean ~> Natural # MLP -> B.Vector n Int
classifications xs mlp =
    fromIntegral . B.maxIndex <$> classifications0 mlp xs

classifications0 :: KnownNat n => Mean ~> Natural # MLP -> B.Vector n (B.Vector MNISTSize Double) -> B.Vector n (B.Vector 10 Double)
classifications0 mlp xs =
    B.zipWith fmap (density <$> mlp >>$>* xs) (B.replicate $ B.generate finiteInt)

l2norm :: RealFloat x => Point (Mean ~> Natural) MLP x -> x
l2norm mlp = sqrt . sum $ (^(2:: Int)) <$> mlp

accuracy
    :: KnownNat n
    => B.Vector n (B.Vector MNISTSize Double,Int)
    -> Mean ~> Natural # MLP
    -> (Double,Double)
accuracy vxys mlp =
    let (xs,ys) = B.unzip vxys
        classy i j = if i == j then 1 else 0
     in ((/ fromIntegral (B.length vxys)) . sum . B.zipWith classy ys $ classifications xs mlp, maximum $ abs <$> mlp)


-- Main --


main :: IO ()
main = do

    txys <- mnistTrainingData

    mlp0 <- realize $ initialize ip

    let tstrm = B.breakStream txys

    let trncrc :: Circuit (B.Vector NBatch (B.Vector MNISTSize Double,Int)) (Mean ~> Natural # MLP)
        trncrc = accumulateCircuit0 mlp0 $ proc (xys,mlp) -> do
            let (xs,ys) = B.unzip xys
                dmlp1 = backpropagation xs ys mlp
                --dmlp1 = differential (stochasticConditionalCrossEntropy xs ys) mlp
                --dmlp2 = differential l2norm mlp
                --dmlp = convexCombination 0.99 dmlp1 dmlp2
                --dmlp' = joinTangentPair mlp (breakChart dmlp)
            adamAscent eps b1 b2 rg -< joinTangentPair mlp (breakChart dmlp1)
            --momentumAscent eps mu -< dmlp'
            --gradientAscent eps -< dmlp'

    vxys0 <- mnistTestData

    let vxys :: B.Vector 10000 (B.Vector MNISTSize Double,Int)
        vxys = fromJust $ B.fromList vxys0

    let ces = take nepchs . takeEvery tbtch . stream tstrm $ trncrc >>> arr (accuracy vxys)

    --let ces = stochasticConditionalCrossEntropy vxys <$> mlps
    sequence_ $ print <$> ces
    --print $ mlp0 >.>* (fst $ B.head vxys)


{-
    let celyt = execEC $ do

            goalLayout
            layout_x_axis . laxis_title .= "Epochs"
            layout_y_axis . laxis_title .= "Negative Log-Likelihood"

            plot . liftEC $ do

                plot_lines_style .= solidLine 3 (opaque red)
                plot_lines_values .= [ zip [(0 :: Int)..] ces ]

    goalRenderableToSVG "mnist" "cross-entropy-descent" 1000 500 $ toRenderable celyt
    -}
