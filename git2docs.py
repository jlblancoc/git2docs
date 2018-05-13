#!/usr/bin/env python3
# ============================================================================
#  git2docs - Generating docs for each Git tag & branch, made easy
#  Copyright (C) 2017-2018 - Jose Luis Blanco Claraco
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#  See docs online https://github.com/jlblancoc/git2docs
# ============================================================================

import atexit
import configparser
import os.path
import string
import sys
import time
import subprocess

VERBOSE = True
MYPATH = os.path.dirname(sys.argv[0])
MYPATH_ABS = os.path.abspath(MYPATH)
LOCKFILE = ''
DO_REMOVE_LOCK = False


def dbgPrint(str):
    if (VERBOSE):
        print('# ' + str)


# Return the list of all remote branches AND tags
def getRemoteGitBranches(git_uri):
    OUT = subprocess.Popen(['sh', '-c', 'git ls-remote '+git_uri+
                            ' | grep -e "tags" -e "heads"'],
                           stdout=subprocess.PIPE).communicate()
    GIT_LS_REM = OUT[0].decode()
    dbgPrint('GIT_LS_REM: ' + GIT_LS_REM)
    #return RET=$(echo "$GIT_LS_REM" |
    # grep -v -e "{}" | awk -F '[/ \t]' '{print $1,$NF}')


def read_cfg(cfg, dict, name):
    s = os.path.expandvars(cfg['config'][name])
    var = string.Template(s).substitute(dict)
    dict[name] = var
    return var

def main():
    # Read config:
    cfg = configparser.ConfigParser()
    cfg.read('./git2docs.cfg')
    var_replcs = {}
    BASEDIR = read_cfg(cfg, var_replcs, 'BASEDIR')
    GIT_CLONEDIR = read_cfg(cfg, var_replcs, 'GIT_CLONEDIR')
    OUT_WWWROOT = read_cfg(cfg, var_replcs, 'OUT_WWWROOT')
    DOCGEN_OUT_DOC_DIR = read_cfg(cfg, var_replcs, 'DOCGEN_OUT_DOC_DIR')

    dbgPrint('BASEDIR: ' + str(BASEDIR))
    dbgPrint('GIT_CLONEDIR: ' + str(GIT_CLONEDIR))
    dbgPrint('OUT_WWWROOT: ' + str(OUT_WWWROOT))
    dbgPrint('DOCGEN_OUT_DOC_DIR ' + str(DOCGEN_OUT_DOC_DIR))

    # Create output dir:
    if not os.path.exists(OUT_WWWROOT):
        os.mkdir(OUT_WWWROOT)

    # Lock file preparation:
    global LOCKFILE
    global DO_REMOVE_LOCK
    LOCKFILE = OUT_WWWROOT + '/.git2docs.lock'
    DO_REMOVE_LOCK = True
    open(LOCKFILE, 'a')

    # Get remote branches:
    GIT_URI = cfg['config']['GIT_URI']
    RB = getRemoteGitBranches(GIT_URI)


# Make sure we cleanup lockfile on exit:
def do_cleanup():
    try:
        if DO_REMOVE_LOCK:
            dbgPrint('DO_REMOVE_LOCK was True: deleting lock file...')
            os.remove(LOCKFILE)
    except:
        print('Exception (do_cleanup): '+str(sys.exc_info()[0]))


atexit.register(do_cleanup)


if __name__ == '__main__':
    try:
        main()
    except:
        print('[main] Exception: '+str(sys.exc_info()[0]))
