-- | Provides parsers for the WebSocket protocol. Uses the attoparsec library.
{-# LANGUAGE BangPatterns, OverloadedStrings, PatternGuards #-}
module Network.WebSockets.Decode
    ( request
    , frame
    ) where

import Control.Applicative (pure, (<$>), (<*>), (*>), (<*))
import Data.Bits (xor, (.&.))

import Data.Attoparsec (Parser, anyWord8, string, takeWhile1, word8)
import Data.Attoparsec.Combinator (manyTill)
import Data.Binary.Get (runGet, getWord16be, getWord64be)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 ()
import Data.ByteString.Internal (c2w)
import Data.Int (Int64)
import qualified Data.Attoparsec as A
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL

import Network.WebSockets.Types

-- | Parse an initial request
request :: Parser Request
request = Request
    <$> requestLine
    <*> manyTill header newline
  where
    space = word8 (c2w ' ')
    newline = string "\r\n"

    requestLine = string "GET" *> space *> takeWhile1 (/= c2w ' ')
        <* space
        <* string "HTTP/1.1" <* newline

    header = (,)
        <$> takeWhile1 (/= c2w ':') 
        <*  string ": "
        <*> takeWhile1 (/= c2w '\r')
        <*  newline

-- | Parse a frame
frame :: Parser Frame
frame = do
    byte0 <- anyWord8
    let fin = byte0 .&. 0x80 == 0x80
        opcode = byte0 .&. 0x0f

    let ft = case opcode of
            0x00 -> Continuation
            0x01 -> Text
            0x02 -> Binary
            0x08 -> Close
            0x09 -> Ping
            0x0a -> Pong
            _    -> error "Unknown opcode"

    byte1 <- anyWord8
    let mask = byte1 .&. 0x80 == 0x80
        lenflag = fromIntegral (byte1 .&. 0x7f)

    len <- case lenflag of
        126 -> fromIntegral . runGet' getWord16be <$> A.take 2
        127 -> fromIntegral . runGet' getWord64be <$> A.take 8
        _   -> return lenflag

    masker <- if mask then xorMask <$> A.take 4 else pure id

    chunks <- take64 len

    return $ Frame fin ft (masker $ BL.fromChunks chunks)
  where
    runGet' g = runGet g . BL.fromChunks . return

    take64 :: Int64 -> Parser [ByteString]
    take64 n
        | n <= 0    = return []
        | otherwise = do
            let n' = min intMax n
            chunk <- A.take (fromIntegral n')
            (chunk :) <$> take64 (n - n')
      where
        intMax :: Int64
        intMax = fromIntegral (maxBound :: Int)

xorMask :: ByteString -> BL.ByteString -> BL.ByteString
xorMask mask = snd . BL.mapAccumL f 0
  where
    len = B.length mask
    f !i !c = let i' = (i + 1) `mod` len
                  m = mask `B.index` i
              in (i', m `xor` c)