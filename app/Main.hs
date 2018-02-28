{- cluster-tree
Gregory W. Schwartz

Hierarchical spectral clustering of data.
-}

{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE DeriveGeneric     #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators     #-}
{-# LANGUAGE StandaloneDeriving #-}

module Main where

-- Standard
import Data.Maybe (fromMaybe)
import GHC.Generics

-- Cabal
import Control.Monad.Except (runExceptT, ExceptT (..))
import Control.Monad.Managed (with, liftIO, Managed (..))
import Data.Char (ord)
import Data.Monoid ((<>))
import Options.Generic
import Safe (atMay)
import qualified Data.Aeson as A
import qualified Data.Aeson.Encode.Pretty as A
import qualified Data.ByteString.Lazy.Char8 as B
import qualified Data.ByteString.Streaming.Char8 as BS
import qualified Data.Csv as CSV
import qualified Data.IntMap.Strict as IMap
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Numeric.LinearAlgebra as H
import qualified Streaming as S
import qualified Streaming.Cassava as S
import qualified Streaming.Prelude as S
import qualified Streaming.With.Lifted as SW

-- Local
import Math.Clustering.Hierarchical.Spectral.Dense
import Math.Clustering.Hierarchical.Spectral.Types


newtype Delimiter  = Delimiter { unDelimiter :: Char } deriving (Read, Show)
newtype Row        = Row { unRow :: Int } deriving (Eq, Ord, Read, Show)
newtype Column     = Column { unColumn :: Int } deriving (Eq, Ord, Read, Show)
newtype OutputTree = OutputTree { unOutputTree :: String } deriving (Read, Show)
newtype MinSize    = MinSize { unMinSize :: Int } deriving (Read, Show)

data ClusteringType = Dense deriving (Read, Show)

instance A.ToJSON Q where
      toEncoding = A.genericToEncoding A.defaultOptions
instance A.FromJSON Q

instance (A.ToJSON a) => A.ToJSON (ClusteringVertex a) where
      toEncoding = A.genericToEncoding A.defaultOptions
instance (A.FromJSON a) => A.FromJSON (ClusteringVertex a)

-- | Command line arguments
data Options = Options { clusteringType :: Maybe String
                                       <?> "([Dense]) Method for clustering data. Dense only so far."
                       , delimiter      :: Maybe Char
                                       <?> "([,] | CHAR) The delimiter of the CSV file."
                       , minSize        :: Maybe Int
                                       <?> "([Nothing] | INT) Minimum size of a cluster."
                       , outputTree     :: Maybe String
                                       <?> "([Nothing] | FILE) The name of the file to output the tree in JSON format."
                       }
               deriving (Generic)

instance ParseRecord Options

-- | Generic error message.
errorMsg = error "Not correct format (requires row,column,value)"

-- | Parse a row of an index file.
parseRow :: [Double] -> ((Int, Int), Double)
parseRow [] = errorMsg
parseRow [i, j, v] = ((round i, round j), v)

-- | Ensure symmetry.
symmetric :: [((Int, Int), Double)] -> [((Int, Int), Double)]
symmetric = concatMap (\((!i, !j), v) -> [((i, j), v), ((j, i), v)])

-- | Get the translated matrix indices.
getNewIndices :: [((Int, Int), Double)] -> [((Int, Int), Double)]
getNewIndices xs =
    fmap
        (\((!i,!j),!v) ->
              ( ( IMap.findWithDefault eMsg i idxMap
                , IMap.findWithDefault eMsg j idxMap
                )
              , v
              )
        )
        xs
  where
    eMsg     = error "Index not found during index conversion."
    indices  = getAllIndices xs
    idxMap   = IMap.fromList $ zip indices [0 ..]

-- | Get the list of all indices.
getAllIndices :: [((Int, Int), Double)] -> [Int]
getAllIndices xs = Set.toAscList . Set.union (getSet fst) $ getSet snd
  where
    getSet f = Set.fromList . fmap (f . fst) $ xs

main :: IO ()
main = do
    opts <- getRecord "cluster-tree, Gregory W. Schwartz.\
                      \ Hierarchical spectral clustering of data Computes real\
                      \ symmetric part of matrix, so ensure the input is real\
                      \ and symmetric. Diagonal should be 0s for\
                      \ adjacency matrix."

    let clusteringType' = maybe Dense read . unHelpful . clusteringType $ opts
        delim'          =
            Delimiter . fromMaybe ',' . unHelpful . delimiter $ opts
        minSize'        = fmap MinSize . unHelpful . minSize $ opts
        outputTree'     = fmap OutputTree . unHelpful . outputTree $ opts
        decodeOpt       = CSV.defaultDecodeOptions
                            { CSV.decDelimiter =
                                fromIntegral (ord . unDelimiter $ delim')
                            }
        encodeOpt       = CSV.defaultEncodeOptions
                            { CSV.encDelimiter =
                                fromIntegral (ord . unDelimiter $ delim')
                            }

    clusteringTree <- flip with return $ do
        let getAssocList = S.toList_ . S.map parseRow

        assocList <-
            fmap (either (error . show) id)
                . runExceptT
                . getAssocList
                . S.decodeWith decodeOpt S.NoHeader
                $ (BS.stdin :: BS.ByteString (ExceptT S.CsvParseException Managed) ())

        let 
            items  = V.fromList $ getAllIndices assocList
            mat    = H.assoc (V.length items, V.length items) 0
                   . symmetric -- Ensure symmetry.
                   . getNewIndices -- Only look at present rows by converting indices.
                   $ assocList

        return $ hierarchicalSpectralCluster (fmap unMinSize minSize') items mat

    let clustering = zip [1..] . getClusterItemsTree $ clusteringTree
        body :: [(Int, Double)]
        body = concatMap
                (\(!c, xs) -> fmap (\ !x -> (x, c)) . V.toList $ xs)
                clustering

    case outputTree' of
        Nothing                -> return ()
        Just (OutputTree file) ->
            B.writeFile file . A.encodePretty $ clusteringTree

    -- | Print final result.
    B.putStr
        . (<>) "item,cluster\n"
        . CSV.encodeWith encodeOpt
        $ body

    return ()