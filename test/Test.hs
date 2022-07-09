import Test.Tasty.QuickCheck as QC
import Test.Tasty.HUnit
import Test.Tasty

import Invariants
import Sym

tests :: TestTree
tests = testGroup "Tests"
  [ invariants
  , symTests
  -- , testCase "2+2=4" $
  --     2+2 @?= 4
  -- , testCase "7 is even" $
  --     assertBool "Oops, 7 is odd" (even 7)
  ]

main :: IO ()
main = defaultMain tests