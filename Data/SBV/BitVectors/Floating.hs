-----------------------------------------------------------------------------
-- |
-- Module      :  Data.SBV.BitVectors.Floating
-- Copyright   :  (c) Levent Erkok
-- License     :  BSD3
-- Maintainer  :  erkokl@gmail.com
-- Stability   :  experimental
--
-- Implementation of floating-point operations mapping to SMT-Lib2 floats
-----------------------------------------------------------------------------

{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Data.SBV.BitVectors.Floating (
         IEEEFloating(..), IEEEFloatConvertable(..)
       , sFloatAsSWord32, sDoubleAsSWord64, sWord32AsSFloat, sWord64AsSDouble
       , blastSFloat, blastSDouble
       ) where

import Control.Monad (join)

import qualified Data.Binary.IEEE754 as DB (wordToFloat, wordToDouble, floatToWord, doubleToWord)

import Data.Int            (Int8,  Int16,  Int32,  Int64)
import Data.Word           (Word8, Word16, Word32, Word64)

import Data.SBV.BitVectors.Data
import Data.SBV.BitVectors.Model
import Data.SBV.BitVectors.AlgReals (isExactRational)
import Data.SBV.Utils.Boolean
import Data.SBV.Utils.Numeric

-- | A class of floating-point (IEEE754) operations, some of
-- which behave differently based on rounding modes. Note that unless
-- the rounding mode is concretely RoundNearestTiesToEven, we will
-- not concretely evaluate these, but rather pass down to the SMT solver.
class (SymWord a, RealFloat a) => IEEEFloating a where
  -- | Compute the floating point absolute value.
  fpAbs             ::                  SBV a -> SBV a

  -- | Compute the unary negation. Note that @0 - x@ is not equivalent to @-x@ for floating-point, since @-0@ and @0@ are different.
  fpNeg             ::                  SBV a -> SBV a

  -- | Add two floating point values, using the given rounding mode
  fpAdd             :: SRoundingMode -> SBV a -> SBV a -> SBV a

  -- | Subtract two floating point values, using the given rounding mode
  fpSub             :: SRoundingMode -> SBV a -> SBV a -> SBV a

  -- | Multiply two floating point values, using the given rounding mode
  fpMul             :: SRoundingMode -> SBV a -> SBV a -> SBV a

  -- | Divide two floating point values, using the given rounding mode
  fpDiv             :: SRoundingMode -> SBV a -> SBV a -> SBV a

  -- | Fused-multiply-add three floating point values, using the given rounding mode. @fpFMA x y z = x*y+z@ but with only
  -- one rounding done for the whole operation; not two. Note that we will never concretely evaluate this function since
  -- Haskell lacks an FMA implementation.
  fpFMA             :: SRoundingMode -> SBV a -> SBV a -> SBV a -> SBV a

  -- | Compute the square-root of a float, using the given rounding mode
  fpSqrt            :: SRoundingMode -> SBV a -> SBV a

  -- | Compute the remainder: @x - y * n@, where @n@ is the truncated integer nearest to x/y. The rounding mode
  -- is implicitly assumed to be @RoundNearestTiesToEven@.
  fpRem             ::                  SBV a -> SBV a -> SBV a

  -- | Round to the nearest integral value, using the given rounding mode.
  fpRoundToIntegral :: SRoundingMode -> SBV a -> SBV a

  -- | Compute the minimum of two floats, respects @infinity@ and @NaN@ values
  fpMin             ::                  SBV a -> SBV a -> SBV a

  -- | Compute the maximum of two floats, respects @infinity@ and @NaN@ values
  fpMax             ::                  SBV a -> SBV a -> SBV a

  -- | Are the two given floats exactly the same. That is, @NaN@ will compare equal to itself, @+0@ will /not/ compare
  -- equal to @-0@ etc. This is the object level equality, as opposed to the semantic equality. (For the latter, just use '.=='.)
  fpIsEqualObject   ::                  SBV a -> SBV a -> SBool

  -- | Is the floating-point number a normal value. (i.e., not denormalized.)
  fpIsNormal :: SBV a -> SBool

  -- | Is the floating-point number a subnormal value. (Also known as denormal.)
  fpIsSubnormal :: SBV a -> SBool

  -- | Is the floating-point number 0? (Note that both +0 and -0 will satisfy this predicate.)
  fpIsZero :: SBV a -> SBool

  -- | Is the floating-point number infinity? (Note that both +oo and -oo will satisfy this predicate.)
  fpIsInfinite :: SBV a -> SBool

  -- | Is the floating-point number a NaN value?
  fpIsNaN ::  SBV a -> SBool

  -- | Is the floating-point number negative? Note that -0 satisfies this predicate but +0 does not.
  fpIsNegative :: SBV a -> SBool

  -- | Is the floating-point number positive? Note that +0 satisfies this predicate but -0 does not.
  fpIsPositive :: SBV a -> SBool

  -- | Is the floating point number -0?
  fpIsNegativeZero :: SBV a -> SBool

  -- | Is the floating point number +0?
  fpIsPositiveZero :: SBV a -> SBool

  -- | Is the floating-point number a regular floating point, i.e., not NaN, nor +oo, nor -oo. Normals or denormals are allowed.
  fpIsPoint :: SBV a -> SBool

  -- Default definitions. Minimal complete definition: None! All should be taken care by defaults
  -- Note that we never evaluate FMA concretely, as there's no fma operator in Haskell
  fpAbs              = lift1  FP_Abs             (Just abs)                Nothing
  fpNeg              = lift1  FP_Neg             (Just negate)             Nothing
  fpAdd              = lift2  FP_Add             (Just (+))                . Just
  fpSub              = lift2  FP_Sub             (Just (-))                . Just
  fpMul              = lift2  FP_Mul             (Just (*))                . Just
  fpDiv              = lift2  FP_Div             (Just (/))                . Just
  fpFMA              = lift3  FP_FMA             Nothing                   . Just
  fpSqrt             = lift1  FP_Sqrt            (Just sqrt)               . Just
  fpRem              = lift2  FP_Rem             (Just fpRemH)             Nothing
  fpRoundToIntegral  = lift1  FP_RoundToIntegral (Just fpRoundToIntegralH) . Just
  fpMin              = lift2  FP_Min             (Just fpMinH)             Nothing
  fpMax              = lift2  FP_Max             (Just fpMaxH)             Nothing
  fpIsEqualObject    = lift2B FP_ObjEqual        (Just fpIsEqualObjectH)   Nothing
  fpIsNormal         = lift1B FP_IsNormal        fpIsNormalizedH
  fpIsSubnormal      = lift1B FP_IsSubnormal     isDenormalized
  fpIsZero           = lift1B FP_IsZero          (== 0)
  fpIsInfinite       = lift1B FP_IsInfinite      isInfinite
  fpIsNaN            = lift1B FP_IsNaN           isNaN
  fpIsNegative       = lift1B FP_IsNegative      (\x -> x < 0 ||       isNegativeZero x)
  fpIsPositive       = lift1B FP_IsPositive      (\x -> x >= 0 && not (isNegativeZero x))
  fpIsNegativeZero x = fpIsZero x &&& fpIsNegative x
  fpIsPositiveZero x = fpIsZero x &&& fpIsPositive x
  fpIsPoint        x = bnot (fpIsNaN x ||| fpIsInfinite x)

-- | SFloat instance
instance IEEEFloating Float

-- | SDouble instance
instance IEEEFloating Double

-- | Capture convertability from/to FloatingPoint representations
-- NB. 'fromSFloat' and 'fromSDouble' are underspecified when given
-- when given a @NaN@, @+oo@, or @-oo@ value that cannot be represented
-- in the target domain. For these inputs, we define the result to be +0, arbitrarily.
class IEEEFloatConvertable a where
  fromSFloat  :: SRoundingMode -> SFloat  -> SBV a
  toSFloat    :: SRoundingMode -> SBV a   -> SFloat
  fromSDouble :: SRoundingMode -> SDouble -> SBV a
  toSDouble   :: SRoundingMode -> SBV a   -> SDouble

-- | A generic converter that will work for most of our instances. (But not all!)
genericFPConverter :: forall a r. (SymWord a, HasKind r, SymWord r, Num r) => Maybe (a -> Bool) -> Maybe (SBV a -> SBool) -> (a -> r) -> SRoundingMode -> SBV a -> SBV r
genericFPConverter mbConcreteOK mbSymbolicOK converter rm f
  | Just w <- unliteral f, Just RoundNearestTiesToEven <- unliteral rm, check w
  = literal $ converter w
  | Just symCheck <- mbSymbolicOK
  = ite (symCheck f) result (literal 0)
  | True
  = result
  where result  = SBV (SVal kTo (Right (cache y)))
        check w = maybe True ($ w) mbConcreteOK
        kFrom   = kindOf f
        kTo     = kindOf (undefined :: r)
        y st    = do msw <- sbvToSW st rm
                     xsw <- sbvToSW st f
                     newExpr st kTo (SBVApp (IEEEFP (FP_Cast kFrom kTo msw)) [xsw])

-- | Check that a given float is a point
ptCheck :: IEEEFloating a => Maybe (SBV a -> SBool)
ptCheck = Just fpIsPoint

instance IEEEFloatConvertable Int8 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Int16 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Int32 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Int64 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Word8 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Word16 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Word32 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Word64 where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

instance IEEEFloatConvertable Float where
  fromSFloat _ f = f
  toSFloat   _ f = f
  fromSDouble    = genericFPConverter Nothing Nothing fp2fp
  toSDouble      = genericFPConverter Nothing Nothing fp2fp

instance IEEEFloatConvertable Double where
  fromSFloat      = genericFPConverter Nothing Nothing fp2fp
  toSFloat        = genericFPConverter Nothing Nothing fp2fp
  fromSDouble _ d = d
  toSDouble   _ d = d

instance IEEEFloatConvertable Integer where
  fromSFloat  = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Float -> Integer))
  toSFloat    = genericFPConverter Nothing Nothing (fromRational . fromIntegral)
  fromSDouble = genericFPConverter Nothing ptCheck (fromIntegral . (fpRound0 :: Double -> Integer))
  toSDouble   = genericFPConverter Nothing Nothing (fromRational . fromIntegral)

-- For AlgReal; be careful to only process exact rationals concretely
instance IEEEFloatConvertable AlgReal where
  fromSFloat  = genericFPConverter Nothing                ptCheck (fromRational . fpRatio0)
  toSFloat    = genericFPConverter (Just isExactRational) Nothing (fromRational . toRational)
  fromSDouble = genericFPConverter Nothing                ptCheck (fromRational . fpRatio0)
  toSDouble   = genericFPConverter (Just isExactRational) Nothing (fromRational . toRational)

-- | Concretely evaluate one arg function, if rounding mode is RoundNearestTiesToEven and we have enough concrete data
concEval1 :: (SymWord a, Floating a) => Maybe (a -> a) -> Maybe SRoundingMode -> SBV a -> Maybe (SBV a)
concEval1 mbOp mbRm a = do op <- mbOp
                           v  <- unliteral a
                           case join (unliteral `fmap` mbRm) of
                             Nothing                     -> (Just . literal) (op v)
                             Just RoundNearestTiesToEven -> (Just . literal) (op v)
                             _                           -> Nothing

-- | Concretely evaluate two arg function, if rounding mode is RoundNearestTiesToEven and we have enough concrete data
concEval2 :: (SymWord a, Floating a) => Maybe (a -> a -> a) -> Maybe SRoundingMode -> SBV a -> SBV a -> Maybe (SBV a)
concEval2 mbOp mbRm a b  = do op <- mbOp
                              v1 <- unliteral a
                              v2 <- unliteral b
                              case join (unliteral `fmap` mbRm) of
                                Nothing                     -> (Just . literal) (v1 `op` v2)
                                Just RoundNearestTiesToEven -> (Just . literal) (v1 `op` v2)
                                _                           -> Nothing

-- | Concretely evaluate a bool producing two arg function, if rounding mode is RoundNearestTiesToEven and we have enough concrete data
concEval2B :: (SymWord a, Floating a) => Maybe (a -> a -> Bool) -> Maybe SRoundingMode -> SBV a -> SBV a -> Maybe SBool
concEval2B mbOp mbRm a b  = do op <- mbOp
                               v1 <- unliteral a
                               v2 <- unliteral b
                               case join (unliteral `fmap` mbRm) of
                                 Nothing                     -> (Just . literal) (v1 `op` v2)
                                 Just RoundNearestTiesToEven -> (Just . literal) (v1 `op` v2)
                                 _                           -> Nothing

-- | Concretely evaluate two arg function, if rounding mode is RoundNearestTiesToEven and we have enough concrete data
concEval3 :: (SymWord a, Floating a) => Maybe (a -> a -> a -> a) -> Maybe SRoundingMode -> SBV a -> SBV a -> SBV a -> Maybe (SBV a)
concEval3 mbOp mbRm a b c = do op <- mbOp
                               v1 <- unliteral a
                               v2 <- unliteral b
                               v3 <- unliteral c
                               case join (unliteral `fmap` mbRm) of
                                 Nothing                     -> (Just . literal) (op v1 v2 v3)
                                 Just RoundNearestTiesToEven -> (Just . literal) (op v1 v2 v3)
                                 _                           -> Nothing

-- | Add the converted rounding mode if given as an argument
addRM :: State -> Maybe SRoundingMode -> [SW] -> IO [SW]
addRM _  Nothing   as = return as
addRM st (Just rm) as = do swm <- sbvToSW st rm
                           return (swm : as)

-- | Lift a 1 arg FP-op
lift1 :: (SymWord a, Floating a) => FPOp -> Maybe (a -> a) -> Maybe SRoundingMode -> SBV a -> SBV a
lift1 w mbOp mbRm a
  | Just cv <- concEval1 mbOp mbRm a
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k    = kindOf a
        r st = do swa  <- sbvToSW st a
                  args <- addRM st mbRm [swa]
                  newExpr st k (SBVApp (IEEEFP w) args)

-- | Lift an FP predicate
lift1B :: (SymWord a, Floating a) => FPOp -> (a -> Bool) -> SBV a -> SBool
lift1B w f a
   | Just v <- unliteral a = literal $ f v
   | True                  = SBV $ SVal KBool $ Right $ cache r
   where r st = do swa <- sbvToSW st a
                   newExpr st KBool (SBVApp (IEEEFP w) [swa])


-- | Lift a 2 arg FP-op
lift2 :: (SymWord a, Floating a) => FPOp -> Maybe (a -> a -> a) -> Maybe SRoundingMode -> SBV a -> SBV a -> SBV a
lift2 w mbOp mbRm a b
  | Just cv <- concEval2 mbOp mbRm a b
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k    = kindOf a
        r st = do swa  <- sbvToSW st a
                  swb  <- sbvToSW st b
                  args <- addRM st mbRm [swa, swb]
                  newExpr st k (SBVApp (IEEEFP w) args)

-- | Lift a 2 arg FP-op, producing bool
lift2B :: (SymWord a, Floating a) => FPOp -> Maybe (a -> a -> Bool) -> Maybe SRoundingMode -> SBV a -> SBV a -> SBool
lift2B w mbOp mbRm a b
  | Just cv <- concEval2B mbOp mbRm a b
  = cv
  | True
  = SBV $ SVal KBool $ Right $ cache r
  where r st = do swa  <- sbvToSW st a
                  swb  <- sbvToSW st b
                  args <- addRM st mbRm [swa, swb]
                  newExpr st KBool (SBVApp (IEEEFP w) args)

-- | Lift a 3 arg FP-op
lift3 :: (SymWord a, Floating a) => FPOp -> Maybe (a -> a -> a -> a) -> Maybe SRoundingMode -> SBV a -> SBV a -> SBV a -> SBV a
lift3 w mbOp mbRm a b c
  | Just cv <- concEval3 mbOp mbRm a b c
  = cv
  | True
  = SBV $ SVal k $ Right $ cache r
  where k    = kindOf a
        r st = do swa  <- sbvToSW st a
                  swb  <- sbvToSW st b
                  swc  <- sbvToSW st c
                  args <- addRM st mbRm [swa, swb, swc]
                  newExpr st k (SBVApp (IEEEFP w) args)

-- | Relationally assert the equivalence between an 'SFloat' and an 'SWord32', when the bit-pattern
-- is interpreted as either type. Useful when analyzing components of a floating point number. Note
-- that this cannot be written as a function, since IEEE754 NaN values are not unique. That is,
-- given a float, there isn't a unique sign/mantissa/exponent that we can match it to.
--
-- The use case would be code of the form:
--
-- @
--     do w <- free_
--        constrain $ sFloatToSWord32 f w
--        ...
-- @
--
-- At which point the variable @w@ can be used to access the bits of the float 'f'.
sFloatAsSWord32 :: SFloat -> SWord32 -> SBool
sFloatAsSWord32 fVal wVal
  | Just f <- unliteral fVal, not (isNaN f) = wVal .== literal (DB.floatToWord f)
  | True                                    = fVal `fpIsEqualObject` sWord32AsSFloat wVal

-- | Relationally assert the equivalence between an 'SDouble' and an 'SWord64', when the bit-pattern
-- is interpreted as either type. See the comments for 'sFloatToSWord32' for details.
sDoubleAsSWord64 :: SDouble -> SWord64 -> SBool
sDoubleAsSWord64 fVal wVal
  | Just f <- unliteral fVal, not (isNaN f) = wVal .== literal (DB.doubleToWord f)
  | True                                    = fVal `fpIsEqualObject` sWord64AsSDouble wVal

-- | Relationally extract the sign\/exponent\/mantissa of a single-precision float. Due to the
-- non-unique representation of NaN's, we have to do this relationally, much like
-- 'sFloatAsSWord32'.
blastSFloat :: SFloat -> (SBool, [SBool], [SBool]) -> SBool
blastSFloat fVal (s, expt, mant)
  | length expt /= 8 || length mant /= 23  = error "SBV.blastSFloat: Need 8-bit expt and 23 bit mantissa"
  | True                                   = sFloatAsSWord32 fVal wVal
 where bits = s : expt ++ mant
       wVal = sum [ite b (2^c) 0 | (b, c) <- zip bits (reverse [(0::Word32) .. 31])]

-- | Relationally extract the sign\/exponent\/mantissa of a double-precision float. Due to the
-- non-unique representation of NaN's, we have to do this relationally, much like
-- 'sDoubleAsSWord64'.
blastSDouble :: SDouble -> (SBool, [SBool], [SBool]) -> SBool
blastSDouble fVal (s, expt, mant)
  | length expt /= 11 || length mant /= 52 = error "SBV.blastSDouble: Need 11-bit expt and 52 bit mantissa"
  | True                                   = sDoubleAsSWord64 fVal wVal
 where bits = s : expt ++ mant
       wVal = sum [ite b (2^c) 0 | (b, c) <- zip bits (reverse [(0::Word64) .. 63])]

-- | Reinterpret the bits in a 32-bit word as a single-precision floating point number
sWord32AsSFloat :: SWord32 -> SFloat
sWord32AsSFloat fVal
  | Just f <- unliteral fVal = literal $ DB.wordToFloat f
  | True                     = SBV (SVal KFloat (Right (cache y)))
  where y st = do xsw <- sbvToSW st fVal
                  newExpr st KFloat (SBVApp (IEEEFP (FP_Reinterpret (kindOf fVal) KFloat)) [xsw])

-- | Reinterpret the bits in a 32-bit word as a single-precision floating point number
sWord64AsSDouble :: SWord64 -> SDouble
sWord64AsSDouble dVal
  | Just d <- unliteral dVal = literal $ DB.wordToDouble d
  | True                     = SBV (SVal KDouble (Right (cache y)))
  where y st = do xsw <- sbvToSW st dVal
                  newExpr st KDouble (SBVApp (IEEEFP (FP_Reinterpret (kindOf dVal) KDouble)) [xsw])

{-# ANN module ("HLint: ignore Reduce duplication" :: String) #-}
