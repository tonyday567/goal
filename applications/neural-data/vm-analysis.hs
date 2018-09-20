{-# LANGUAGE FlexibleContexts,TypeFamilies,TypeOperators,ScopedTypeVariables,DataKinds #-}

import NeuralData

import Goal.Core
import Goal.Geometry
import Goal.Probability
import qualified Goal.Core.Vector.Boxed as B
import qualified Goal.Core.Vector.Storable as S

import qualified Data.ByteString.Lazy as BS
import qualified Data.Csv as CSV

import Data.Semigroup ((<>))


--- Globals ---


eps :: Double
eps = -0.2

nepchs :: Int
nepchs = 100


--- CLI ---


--- Functions ---


responseStatisticsVM
    :: forall k k' r . (KnownNat k, KnownNat k', k' <= k)
    => [(Response k,Double)]
    -> Int
    -> Proxy k'
    -> Random r (CoefficientsOfVariation, VonMisesInformations)
responseStatisticsVM zxss n prxk' = do
    let ppc = fitPPC zxss
    (cvs, (idxss,mnidxs,mxidxs)) <- responseStatistics zxss n prxk'
    let ppcss = subSamplePPC ppc <$> idxss
        mnppc = subSamplePPC ppc mnidxs
        mxppc = subSamplePPC ppc mxidxs
        mnfi = averageFisherInformation mnppc
        mxfi = averageFisherInformation mxppc
        avfi = average $ averageFisherInformation <$> ppcss
    return (cvs, VonMisesInformations avfi mnfi mxfi)

fitPPC
    :: forall k . KnownNat k
    => [(Response k,Double)]
    -> Mean #> Natural # Neurons k <* VonMises
fitPPC xzs =
    let sps :: S.Vector k (Source # VonMises)
        sps = S.map (\mu -> Point $ S.fromTuple (mu,1)) $ S.range 0 (2*pi)
        ppc0 = vonMisesPopulationEncoder True (Left 1) sps
        (zs,xs) = unzip xzs
        backprop p = joinTangentPair p $ stochasticConditionalCrossEntropyDifferential xs zs p
     in (vanillaGradientSequence backprop eps defaultAdamPursuit ppc0 !! nepchs)

ppcStimulusDerivatives
    :: KnownNat k => Mean #> Natural # Neurons k <* VonMises
    -> SamplePoint VonMises
    -> S.Vector k Double
ppcStimulusDerivatives ppc x =
    let fxs = coordinates . dualTransition $ ppc >.> mx
        tcs = toRows . snd $ splitAffine ppc
     in S.zipWith zipper fxs tcs
    where mx = sufficientStatistic x
          (cx,sx) = S.toPair $ coordinates mx
          zipper fx (Point cs) =
              let (tht1,tht2) = S.toPair cs
               in fx*(cx * tht2 - sx * tht1)

fisherInformation
    :: KnownNat k
    => Mean #> Natural # Neurons k <* VonMises
    -> SamplePoint VonMises
    -> Double
fisherInformation ppc x =
    let fxs2' = S.map square $ ppcStimulusDerivatives ppc x
        fxs = coordinates . dualTransition $ ppc >.>* x
     in S.sum $ S.zipWith (/) fxs2' fxs

averageFisherInformation
    :: KnownNat k
    => Mean #> Natural # Neurons k <* VonMises
    -> Double
averageFisherInformation ppc =
    average $ fisherInformation ppc <$> tail (range 0 (2*pi) 100)


--- Analysis ---


vmAnalyzeCoefficientOfVariation0
    :: forall k r . KnownNat k
    => Int
    -> [([Int], Double)]
    -> Proxy k
    -> Random r [(CoefficientsOfVariation,VonMisesInformations)]
vmAnalyzeCoefficientOfVariation0 nsmps zxs0 _ = do

    let zxs :: [(Response k, Double)]
        zxs = strengthenNeuralData zxs0

    (allcvs :: B.Vector k (CoefficientsOfVariation, VonMisesInformations))
        <- B.generatePM' $ responseStatisticsVM zxs nsmps

    return $ B.toList allcvs

vmAnalyzeCoefficientOfVariation
    :: Int -> [([Int],Double)] -> Random r [(CoefficientsOfVariation,VonMisesInformations)]
vmAnalyzeCoefficientOfVariation nsmps zxs =
    withNat (getPopulationSize zxs) $ vmAnalyzeCoefficientOfVariation0 nsmps zxs



--- CLI ---


data AnalysisOpts = AnalysisOpts String String Int

cvOpts :: Parser AnalysisOpts
cvOpts = AnalysisOpts
    <$> strArgument
        ( help "Which data collection to plot" )
    <*> strOption
        ( long "dataset" <> short 'd' <> help "Which dataset to plot" <> value "")
    <*> option auto (long "nsamples" <> help "number of samples to generate" <> short 'n' <> value 1)

runOpts :: AnalysisOpts -> IO ()
runOpts (AnalysisOpts clcstr dststr nsmps) = do

    let clc = Collection clcstr

    dsts <- if dststr == ""
               then getDatasets clc
               else return [Dataset dststr]

    zxss <- mapM (getNeuralData clc) dsts

    allcsvss <- realize $ mapM (vmAnalyzeCoefficientOfVariation nsmps) zxss

    forM_ allcsvss $ \allcsvs -> do

        let (cvcvs,ficvs) = unzip allcsvs

        BS.writeFile (clcstr ++ "/analysis/cv/" ++ dststr ++ ".csv")
            $ CSV.encodeDefaultOrderedByName cvcvs

        BS.writeFile (clcstr ++ "/analysis/fi/" ++ dststr ++ ".csv")
            $ CSV.encodeDefaultOrderedByName ficvs


--- Main ---


main :: IO ()
main = do

    let opts = info (cvOpts <**> helper) (fullDesc <> progDesc prgstr)
        prgstr = "Analyze the coefficient of variation of the total population activity in neural data"

    runOpts =<< execParser opts


