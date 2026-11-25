#!/usr/bin/env python3
import sys
sys.path.insert(0,'/home/hatch/workspace/suikoden/kit/work/_melsel')
from mipsx import *
if __name__=='__main__':
    dump(sys.argv[1], 0x80010000, int(sys.argv[2],16), int(sys.argv[3]))
