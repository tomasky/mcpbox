#!/usr/bin/env python3
"""Echo fixture with startup records, for observing daemon process reuse."""

import json
import os
import sys

from echo_server import main


if __name__ == "__main__":
    with open(sys.argv[1], "a", encoding="utf-8") as log:
        log.write(json.dumps({"pid": os.getpid(), "cwd": os.getcwd()}) + "\n")
    main()
