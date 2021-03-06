-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.Examples.BitPrecise.PrefixSum
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- The PrefixSum algorithm over power-lists and proof of
-- the Ladner-Fischer implementation.
-- See <http://www.cs.utexas.edu/users/psp/powerlist.pdf>
-- and <http://www.cs.utexas.edu/~plaxton/c/337/05f/slides/ParallelRecursion-4.pdf>.
-----------------------------------------------------------------------------

{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.SBV.Examples.BitPrecise.PrefixSum where

import Data.SBV
import Data.SBV.Internals (runSymbolic)

----------------------------------------------------------------------
-- * Formalizing power-lists
----------------------------------------------------------------------

-- | A poor man's representation of powerlists and
-- basic operations on them: <http://www.cs.utexas.edu/users/psp/powerlist.pdf>.
-- We merely represent power-lists by ordinary lists.
type PowerList a = [a]

-- | The tie operator, concatenation.
tiePL :: PowerList a -> PowerList a -> PowerList a
tiePL = (++)

-- | The zip operator, zips the power-lists of the same size, returns
-- a powerlist of double the size.
zipPL :: PowerList a -> PowerList a -> PowerList a
zipPL []     []     = []
zipPL (x:xs) (y:ys) = x : y : zipPL xs ys
zipPL _      _      = error "zipPL: nonsimilar powerlists received"

-- | Inverse of zipping.
unzipPL :: PowerList a -> (PowerList a, PowerList a)
unzipPL = unzip . chunk2
  where chunk2 []       = []
        chunk2 (x:y:xs) = (x,y) : chunk2 xs
        chunk2 _        = error "unzipPL: malformed powerlist"

----------------------------------------------------------------------
-- * Reference prefix-sum implementation
----------------------------------------------------------------------

-- | Reference prefix sum (@ps@) is simply Haskell's @scanl1@ function.
ps :: (a, a -> a -> a) -> PowerList a -> PowerList a
ps (_, f) = scanl1 f

----------------------------------------------------------------------
-- * The Ladner-Fischer parallel version
----------------------------------------------------------------------

-- | The Ladner-Fischer (@lf@) implementation of prefix-sum. See <http://www.cs.utexas.edu/~plaxton/c/337/05f/slides/ParallelRecursion-4.pdf>
-- or pg. 16 of <http://www.cs.utexas.edu/users/psp/powerlist.pdf>.
lf :: (a, a -> a -> a) -> PowerList a -> PowerList a
lf _ []         = error "lf: malformed (empty) powerlist"
lf _ [x]        = [x]
lf (zero, f) pl = zipPL (zipWith f (rsh lfpq) p) lfpq
   where (p, q) = unzipPL pl
         pq     = zipWith f p q
         lfpq   = lf (zero, f) pq
         rsh xs = zero : init xs


----------------------------------------------------------------------
-- * Sample proofs for concrete operators
----------------------------------------------------------------------

-- | Correctness theorem, for a powerlist of given size, an associative operator, and its left-unit element.
flIsCorrect :: Int -> (forall a. (OrdSymbolic a, Num a, Bits a) => (a, a -> a -> a)) -> Symbolic SBool
flIsCorrect n zf = do
        args :: PowerList SWord32 <- mkForallVars n
        return $ ps zf args .== lf zf args

-- | Proves Ladner-Fischer is equivalent to reference specification for addition.
-- @0@ is the left-unit element, and we use a power-list of size @8@.
thm1 :: IO ThmResult
thm1 = prove $ flIsCorrect  8 (0, (+))

-- | Proves Ladner-Fischer is equivalent to reference specification for the function @max@.
-- @0@ is the left-unit element, and we use a power-list of size @16@.
thm2 :: IO ThmResult
thm2 = prove $ flIsCorrect 16 (0, smax)

----------------------------------------------------------------------
-- * Inspecting symbolic traces
----------------------------------------------------------------------

-- | A symbolic trace can help illustrate the action of Ladner-Fischer. This
-- generator produces the actions of Ladner-Fischer for addition, showing how
-- the computation proceeds:
--
-- >>> ladnerFischerTrace 8
-- INPUTS
--   s0 :: SWord8
--   s1 :: SWord8
--   s2 :: SWord8
--   s3 :: SWord8
--   s4 :: SWord8
--   s5 :: SWord8
--   s6 :: SWord8
--   s7 :: SWord8
-- CONSTANTS
--   s_2 = False
--   s_1 = True
-- TABLES
-- ARRAYS
-- UNINTERPRETED CONSTANTS
-- USER GIVEN CODE SEGMENTS
-- AXIOMS
-- DEFINE
--   s8 :: SWord8 = s0 + s1
--   s9 :: SWord8 = s2 + s8
--   s10 :: SWord8 = s2 + s3
--   s11 :: SWord8 = s8 + s10
--   s12 :: SWord8 = s4 + s11
--   s13 :: SWord8 = s4 + s5
--   s14 :: SWord8 = s11 + s13
--   s15 :: SWord8 = s6 + s14
--   s16 :: SWord8 = s6 + s7
--   s17 :: SWord8 = s13 + s16
--   s18 :: SWord8 = s11 + s17
-- CONSTRAINTS
-- OUTPUTS
--   s0
--   s8
--   s9
--   s11
--   s12
--   s14
--   s15
--   s18
ladnerFischerTrace :: Int -> IO ()
ladnerFischerTrace n = gen >>= print
  where gen = runSymbolic (True, defaultSMTCfg) $ do args :: [SWord8] <- mkForallVars n
                                                     mapM_ output $ lf (0, (+)) args

-- | Trace generator for the reference spec. It clearly demonstrates that the reference
-- implementation fewer operations, but is not parallelizable at all:
--
-- >>> scanlTrace 8
-- INPUTS
--   s0 :: SWord8
--   s1 :: SWord8
--   s2 :: SWord8
--   s3 :: SWord8
--   s4 :: SWord8
--   s5 :: SWord8
--   s6 :: SWord8
--   s7 :: SWord8
-- CONSTANTS
--   s_2 = False
--   s_1 = True
-- TABLES
-- ARRAYS
-- UNINTERPRETED CONSTANTS
-- USER GIVEN CODE SEGMENTS
-- AXIOMS
-- DEFINE
--   s8 :: SWord8 = s0 + s1
--   s9 :: SWord8 = s2 + s8
--   s10 :: SWord8 = s3 + s9
--   s11 :: SWord8 = s4 + s10
--   s12 :: SWord8 = s5 + s11
--   s13 :: SWord8 = s6 + s12
--   s14 :: SWord8 = s7 + s13
-- CONSTRAINTS
-- OUTPUTS
--   s0
--   s8
--   s9
--   s10
--   s11
--   s12
--   s13
--   s14
--
scanlTrace :: Int -> IO ()
scanlTrace n = gen >>= print
  where gen = runSymbolic (True, defaultSMTCfg) $ do args :: [SWord8] <- mkForallVars n
                                                     mapM_ output $ ps (0, (+)) args

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
