{-# LANGUAGE StandaloneDeriving, DeriveDataTypeable #-}
module MuCheck.Interpreter where

import qualified Language.Haskell.Interpreter as I
import Control.Monad.Trans ( liftIO )
import qualified Test.QuickCheck.Test as Qc
import qualified Test.HUnit as HUnit
import qualified Test.Hspec.Core.Runner as Hspec
import Data.Typeable
import MuCheck.Utils.Print (showA, showAS, (./.))
import Data.Either (partitionEithers, rights)
import Data.List((\\), groupBy, sortBy, intercalate, isInfixOf)
import Data.Time.Clock
import Data.Function (on)

import MuCheck.Run.Common
import MuCheck.Run.QuickCheck
import MuCheck.Run.HUnit
import MuCheck.Run.Hspec

checkQuickCheckOnMutants :: [String] -> String -> [String] -> String -> IO [Qc.Result]
checkQuickCheckOnMutants = mutantCheckSummary

checkHUnitOnMutants :: [String] -> String -> [String] -> String -> IO [HUnit.Counts]
checkHUnitOnMutants = mutantCheckSummary

checkHspecOnMutants :: [String] -> String -> [String] -> String -> IO [Hspec.Summary]
checkHspecOnMutants = mutantCheckSummary

-- main entry point
mutantCheckSummary :: (Summarizable a, Show a) => [String] -> String -> [String] -> FilePath -> IO [a]
mutantCheckSummary mutantFiles topModule evalSrcLst logFile  = do
  results <- mapM (runCodeOnMutants mutantFiles topModule) evalSrcLst
  let singleTestSummaries = zip evalSrcLst $ map (testSummary mutantFiles) results
      tssum  = multipleCheckSummary (isSuccess . snd) results
  -- print results to terminal
  putStrLn $ delim ++ "Overall Results:"
  putStrLn $ terminalSummary tssum
  putStrLn $ showAS $ map showBrief singleTestSummaries
  putStr delim
  -- print results to logfile
  appendFile logFile $ "OVERALL RESULTS:\n" ++ tssum_log tssum ++ showAS (map showDetail singleTestSummaries)
  -- hacky solution to avoid printing entire results to stdout and to give
  -- guidance to the type checker in picking specific Summarizable instances
  return $ tail [head $ map snd $ snd $ partitionEithers $ head results]
  where showDetail (method, msum) = delim ++ showBrief (method, msum) ++ "\n" ++ tsum_log msum
        showBrief (method, msum) = showAS [method,
                                           "\tTotal number of mutants:\t" ++ show (tsum_numMutants msum),
                                           "\tFailed to Load:\t" ++ show (tsum_loadError msum),
                                           "\tNot Killed:\t" ++ show (tsum_notKilled msum),
                                           "\tKilled:\t" ++ show (tsum_killed msum),
                                           "\tOthers:\t" ++ show (tsum_others msum),
                                           ""]
        terminalSummary tssum = showAS ["Total number of mutants:\t" ++ show (tssum_numMutants tssum),
                                        "Total number of alive mutants:\t" ++ show (tssum_alive tssum),
                                        "Total number of load errors:\t" ++ show (tssum_errors tssum),
                                        ""]
        delim = "\n" ++ replicate 25 '=' ++ "\n"


-- Interpreter Functionalities
-- Examples
-- t = runInterpreter (evalMethod "Examples/Quicksort.hs" "Quicksort" "quickCheckResult idEmp")
runCodeOnMutants mutantFiles topModule evalStr = mapM (evalMyStr evalStr) mutantFiles
  where evalMyStr evalStr file = do putStrLn $ ">" ++ ":" ++ file ++ ":" ++ topModule ++ ":" ++ evalStr ++ ">"
                                    I.runInterpreter (evalMethod file topModule evalStr)

-- Given the filename, modulename, method to evaluate, evaluate, and return
-- result as a pair.
evalMethod :: (I.MonadInterpreter m, Typeable t) => String -> String -> String -> m (String, t)
evalMethod fileName topModule evalStr = do
  I.loadModules [fileName]
  I.setTopLevelModules [topModule]
  result <- I.interpret evalStr (I.as :: (Typeable a => IO a)) >>= liftIO
  return (fileName, result)


-- we assume that checking each prop results in the same number of errorCases and executedCases
multipleCheckSummary isSuccessFunction results
  | not (checkLength results) = error "Output lengths differ for some properties."
  | otherwise = TSSum {tssum_numMutants = countMutants,
                       tssum_alive = countAlive,
                       tssum_errors= countErrors,
                       tssum_log = logMsg}
  where executedCases = groupBy ((==) `on` fst) . sortBy (compare `on` fst) . rights $ concat results
        allSuccesses = [rs | rs <- executedCases, length rs == length results, all isSuccessFunction rs]
        countAlive = length allSuccesses
        countErrors = countMutants - length executedCases
        logMsg = showA allSuccesses
        checkLength results = and $ map ((==countMutants) . length) results ++ map ((==countExecutedCases) . length) executedCases
        countExecutedCases = length . head $ executedCases
        countMutants = length . head $ results

