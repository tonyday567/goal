{-# LANGUAGE TypeFamilies,TypeOperators,FlexibleContexts,DataKinds,Arrows #-}

--- Imports ---


import Goal.Core
import Goal.Geometry
import Goal.Probability
import Goal.Simulation

import qualified Goal.Core.Vector.Boxed as B

--- Globals ---


-- Manifolds --

type Latent = Categorical Int 3
type Observable = Sum (MeanNormal (1/1)) (MeanNormal (1/2))
type Harmonium' = Latent <*> Observable

-- Mixture Distributions --

mux1,mux2,mux3,muy1,muy2,muy3 :: Double
mux1 = 1.5
muy1 = 0.5
mux2 = -1.5
muy2 = 0.5
mux3 = 0
muy3 = -0.5

nrm1,nrm2,nrm3 :: Source # Observable
nrm1 = Point $ B.doubleton mux1 muy1
nrm2 = Point $ B.doubleton mux2 muy2
nrm3 = Point $ B.doubleton mux3 muy3

nrms :: [Source # Observable]
nrms = [nrm1,nrm2,nrm3]

mix1,mix2 :: Double
mix1 = 0.25
mix2 = 0.25

trucat :: Source # Latent
trucat = Point $ B.doubleton mix1 mix2

-- Training --

w0 :: Source # Normal
w0 = Point $ B.doubleton 0 0.001

tprxy :: Proxy 100
tprxy = Proxy

vprxy :: Proxy 100
vprxy = Proxy

eps,bt1,bt2,rg :: Double
eps = -0.01
bt1 = 0.9
bt2 = 0.999
rg = 1e-8

type NBatch = 10

nepchs,trnepchn :: Int
nepchs = 51
trnepchn = 500

-- Functions --

sampleMixture :: KnownNat k => Proxy k -> Random s (B.Vector k (Int,(Double,Double)))
sampleMixture _ = do
    cats <- B.replicateM $ sample trucat
    xys <- mapM sample $ (nrms !!) <$> cats
    return $ B.zip cats xys

filterCat :: [(Int,(Double,Double))] -> Int -> [(Double,Double)]
filterCat cxys n = snd <$> filter ((== n) . fst) cxys


--- Main ---


main :: IO ()
main = do

    vcxys <- realize $ sampleMixture vprxy
    txys <- realize $ fmap snd <$> sampleMixture tprxy
    let vxys = snd <$> vcxys

    hrm0 <- realize $ initialize w0

    rmly <- realize (accumulateRandomFunction0 $ uncurry estimateCategoricalHarmoniumDifferentials)

    let trncrc :: Circuit (B.Vector NBatch (Double,Double)) (Natural # Harmonium')
        trncrc = accumulateCircuit0 hrm0 $ proc (xs,hrm) -> do
            dhrm <- rmly -< (xs,hrm)
            let dhrmpr = joinTangentPair hrm (breakChart dhrm)
            adamAscent eps bt1 bt2 rg -< dhrmpr

    let hrmss = take nepchs . takeEvery trnepchn $ stream (cycle . toList $ B.breakEvery txys) trncrc

    let anll hrm = average $ categoricalHarmoniumNegativeLogLikelihood hrm <$> vxys
        anlls = anll <$> hrmss

    let hrm1 = last hrmss
        [mux1',muy1'] = listCoordinates . toSource $ conditionalObservableDistribution hrm1 0
        [mux2',muy2'] = listCoordinates . toSource $ conditionalObservableDistribution hrm1 1
        [mux3',muy3'] = listCoordinates . toSource $ conditionalObservableDistribution hrm1 2

    let (_,rprms) = categoricalHarmoniumRectificationParameters hrm1
        (nl,_,_) = splitHarmonium hrm1

    let def' = def {_la_nLabels = 3}

    let [mix1',mix2'] = listCoordinates $ toSource $ rprms <+> nl
        mix3' = 1 - mix1' - mix2'

    putStrLn "Cluster 1:"
    putStrLn $ "Mixture Parameter: " ++ show mix1' ++ ", Mean: " ++ show (mux1',muy1')
    putStrLn "Cluster 2:"
    putStrLn $ "Mixture Parameter: " ++ show mix2' ++ ", Mean: " ++ show (mux2',muy2')
    putStrLn "Cluster 3:"
    putStrLn $ "Mixture Parameter: " ++ show mix3' ++ ", Mean: " ++ show (mux3',muy3')

    let anllrnbl = toRenderable . execEC $ do

            goalLayout

            layout_y_axis . laxis_generate .= autoScaledAxis def'

            layout_x_axis . laxis_title .= "Epoch"
            layout_y_axis . laxis_title .= "-Log-Likelihood"

            plot . liftEC $ do

                plot_lines_style .= solidLine 3 (opaque black)
                plot_lines_values .= [zip [0..nepchs] anlls]

    let clstrrnbl = toRenderable . execEC $ do

            let vcxys' = toList vcxys

            goalLayout

            layout_x_axis . laxis_title .= "x"
            layout_y_axis . laxis_title .= "y"

            layout_x_axis . laxis_generate .= scaledAxis def' (-3,3)
            layout_y_axis . laxis_generate .= scaledAxis def' (-2,2)

            plot . liftEC $ do

                plot_points_values .= [(mux1,muy1)]
                plot_points_style .= filledCircles 7 (opaque red)

            plot . liftEC $ do

                plot_points_values .= [(mux2,muy2)]
                plot_points_style .= filledCircles 7 (opaque blue)

            plot . liftEC $ do

                plot_points_values .= [(mux3,muy3)]
                plot_points_style .= filledCircles 7 (opaque green)

            plot . liftEC $ do

                plot_points_values .= filterCat vcxys' 0
                plot_points_style .= filledCircles 3 (opaque red)

            plot . liftEC $ do

                plot_points_values .= filterCat vcxys' 1
                plot_points_style .= filledCircles 3 (opaque blue)

            plot . liftEC $ do

                plot_points_values .= filterCat vcxys' 2
                plot_points_style .= filledCircles 3 (opaque green)

            plot . liftEC $ do

                plot_points_values .= [(mux1',muy1'),(mux2',muy2'),(mux3',muy3')]
                plot_points_style .= filledCircles 6 (opaque black)


    goalRenderableToSVG "simulation/clustering" "clusters" 500 250 clstrrnbl
    goalRenderableToSVG "simulation/clustering" "cluster-gradient-descent" 500 150 anllrnbl
