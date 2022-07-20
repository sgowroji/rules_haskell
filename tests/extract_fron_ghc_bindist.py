import os
import sys

current_dir = os.path.dirname( __file__ )
haskell_dir = os.path.join( current_dir, '..', 'haskell')
sys.path.append( haskell_dir )

import gen_ghc_bindist

version_numbers = [x['version'] for x in gen_ghc_bindist.VERSIONS]

print("::set-output name=ghc-matrix::", version_numbers)
