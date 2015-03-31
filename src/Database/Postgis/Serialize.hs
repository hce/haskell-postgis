{-# LANGUAGE GADTs, FlexibleInstances, ConstraintKinds, UndecidableInstances, RankNTypes #-}

module Database.Postgis.Serialize  where

import Database.Postgis.Utils
import Database.Postgis.Geometry
import Data.Serialize 
import Data.Word
import Development.Placeholders
import Data.ByteString.Lex.Integral
import Data.Bits
import Control.Applicative ((<*>), (<$>))
import Data.Binary.IEEE754
import System.Endian
import Control.Monad.Reader
import Data.Int

import qualified Data.Vector as V
import qualified Data.ByteString as BS


import Data.Typeable

readGeometry :: BS.ByteString -> Geometry 
readGeometry bs = case runGet parseGeometry bs of
           Left e -> error $ "failed parse" ++ e
           Right g -> g 


data Header = Header {
    _byteOrder :: Endianness
  , _geoType :: Int
  , _srid :: SRID
} deriving (Show)


class Hexable a where
  toHex :: a -> BS.ByteString
  fromHex :: BS.ByteString -> a

instance Hexable Int where
  toHex = toHexInt
  fromHex = fromHexInt

instance Hexable Double where
  fromHex = wordToDouble . fromHexInt 
  toHex = toHexInt . doubleToWord

makeHeader :: EWKBGeometry a => SRID -> a -> Header
makeHeader s geo =
  let gt = geoType geo
      wOr acc (p, h) = if p then h .|. acc else acc
      typ = foldl wOr gt [(hasM geo, wkbM), (hasZ geo, wkbZ), (s /= Nothing, wkbSRID)]   
  in Header getSystemEndianness typ s 


instance Serialize Geometry where
  get = parseGeometry
  put = writeGeometry

parseGeometry :: Get Geometry 
parseGeometry = do
    h <- lookAhead get
    let tVal = (_geoType h) .&. ewkbTypeOffset
    case tVal of
      1 -> mkGeo h GeoPoint parseGeoPoint
      2 -> mkGeo h GeoLineString parseLineString 
      3 -> mkGeo h GeoPolygon parsePolygon 
      4 -> mkGeo h GeoMultiPoint parseMultiPoint 
      5 -> mkGeo h GeoMultiLineString parseMultiLineString
      6 -> mkGeo h GeoMultiPolygon  parseMultiPolygon 
      _ -> error "not yet implemented"

mkGeo :: Header -> (SRID -> a -> Geometry) -> Parser a -> Get Geometry
mkGeo h cons p = (cons (_srid h)) <$> runReaderT p h

instance Serialize Header where 
  put (Header bo gt s) = put bo >> writeNum bo gt >> writeMaybeNum bo s
  get = parseHeader

parseHeader :: Get Header  
parseHeader = do 
    or <- get	
    t <- parseInt' or
    s <- if t .&. wkbSRID > 0 then Just <$> parseInt' or  else return Nothing 
    return $ Header or t s

parseInt' :: Endianness -> Get Int
parseInt' = parseNumber 8

parseInt :: Parser Int
parseInt = (parseInt' <$> (asks _byteOrder)) >>= lift

parseDouble' :: Endianness -> Get Double 
parseDouble' = parseNumber 16

parseNumber :: (Hexable a , Num a) => Int -> Endianness -> Get a
parseNumber l end = do
  bs <- getByteString l
  case end of 
    BigEndian -> return $ fromHex bs
    LittleEndian -> return . fromHex . readLittleEndian $ bs 

parseDouble :: Parser Double
parseDouble = (parseDouble' <$> (asks _byteOrder)) >>= lift

instance Serialize Endianness where
  put BigEndian = putByteString $ toHex (0::Int)
  put LittleEndian = putByteString $ toHex (1::Int)
  get = do
    bs <- getByteString 2
    case fromHex bs :: Int of
      0 -> return BigEndian
      1 -> return LittleEndian
      _ -> error $ "not an endian: " ++ show bs


type Parser = ReaderT Header Get

parseNum' :: (Show a, Num a, Hexable a) => Endianness -> Get a
parseNum' BigEndian =  fromHex <$> get
parseNum' LittleEndian = (fromHex . readLittleEndian) <$> get
  

parseNum :: (Show a, Num a, Hexable a) => Parser a
parseNum = do
  end <- asks _byteOrder
  lift $ parseNum' end 

parseGeoPoint :: Parser Point
parseGeoPoint = lift parseHeader >> parsePoint

parsePoint :: Parser Point
parsePoint = do
    gt <- asks _geoType 
    let hasM = if (gt .&. wkbM) > 0 then True else False 
        hasZ = if (gt .&. wkbZ) > 0 then True else False
    x <- parseDouble
    y <- parseDouble
    z <- if hasZ then Just <$> parseDouble else return Nothing
    m <- if hasM then Just <$> parseDouble else return Nothing
    return $ Point x y z m

parseSegment :: Parser (V.Vector Point)
parseSegment = parseInt >>= (\n -> V.replicateM n parsePoint) 
  
parseRing :: Parser LinearRing
parseRing = LinearRing <$> parseSegment 

parseLineString :: Parser LineString 
parseLineString = lift parseHeader >> LineString <$> parseSegment

parsePolygon :: Parser Polygon 
parsePolygon = lift parseHeader >> Polygon <$> (parseInt >>= (\n -> V.replicateM n parseRing))

parseMultiPoint :: Parser MultiPoint 
parseMultiPoint = do
  lift parseHeader
  n <- parseInt 
  ps <- V.replicateM n parseGeoPoint
  return $ MultiPoint ps

parseMultiLineString :: Parser MultiLineString 
parseMultiLineString = do
  lift parseHeader
  n <- parseInt
  ls <- V.replicateM n parseLineString 
  return $ MultiLineString ls

parseMultiPolygon :: Parser MultiPolygon 
parseMultiPolygon = do 
  lift parseHeader
  n <- parseInt
  ps <- V.replicateM n parsePolygon
  return $ MultiPolygon ps


writeNum :: (Num a, Hexable a) => Endianness -> Putter a
writeNum BigEndian n = put $ toHex n
writeNum LittleEndian n = (put . readLittleEndian . toHex) n

writeMaybeNum :: (Num a, Hexable a) => Endianness -> Putter (Maybe a)
writeMaybeNum end (Just n)  = writeNum end n 
writeMaybeNum end Nothing = return () 

writePoint :: Putter Point 
writePoint p = do
  let bo = getSystemEndianness
  writeNum bo $ _x p
  writeNum bo $ _y p
  writeMaybeNum bo $ _m p
  writeMaybeNum bo $ _z p

writeRing :: Putter LinearRing
writeRing (LinearRing v) = do
  writeNum getSystemEndianness $ V.length v  
  V.mapM_ writePoint v
  return ()

writeGeometry :: Putter Geometry
writeGeometry (GeoPoint s p) = do
  put $ makeHeader s p
  writePoint p
  return ()
writeGeometry (GeoLineString s ls@(LineString v)) = do
  put $ makeHeader s ls 
  writeNum getSystemEndianness $ V.length v
  V.mapM_ writePoint v
  return ()

writeGeometry (GeoPolygon s pg@(Polygon rs)) = do
  put $ makeHeader s pg
  writeNum getSystemEndianness $ V.length rs 
  V.mapM_ writeRing rs
  return ()

writeGeometry (GeoMultiPoint s mp@(MultiPoint ps)) = do
  put $ makeHeader s mp
  writeNum getSystemEndianness $ V.length ps 
  V.mapM_ (writeGeometry . GeoPoint s)  ps
  return ()

writeGeometry (GeoMultiLineString s mls@(MultiLineString ls)) = do
  put $ makeHeader s mls
  writeNum getSystemEndianness $ V.length ls 
  V.mapM_ (writeGeometry . GeoLineString s) ls
  return ()

writeGeometry (GeoMultiPolygon s mpg@(MultiPolygon ps)) = do
  put $ makeHeader s mpg
  writeNum getSystemEndianness $ V.length ps 
  V.mapM_ (writeGeometry . GeoPolygon s)  ps
  return ()

