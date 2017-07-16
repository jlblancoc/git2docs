#!/bin/bash
# ============================================================================
#  git2docs - Generating docs for each Git tag & branch, made easy
#  Copyright (C) 2017 - Jose Luis Blanco Claraco
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

set -e

# User set-up:
MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"  # https://stackoverflow.com/a/246128/1631514
source $MYDIR/config.sh


# Use:: $1=Git URI
function getRemoteGitBranches
{
	GIT_LS_REM=$(git ls-remote $1 | grep -e "tags" -e "heads")
	RET=$(echo "$GIT_LS_REM" | grep -v -e "{}" | awk -F '[/ \t]' '{print $1,$NF}')
	
	echo "$RET"
}

function mainGit2Docs
{
	LIST_GIT_ITEMS=$(getRemoteGitBranches $GIT_URI)

	echo "All git items:"	
	echo "$LIST_GIT_ITEMS"

	declare -a git_lines
	readarray -t git_lines <<< "$LIST_GIT_ITEMS"

	# process each remote branch or tag
	for git_item_line in "${git_lines[@]}";
	do
		echo "Processing: $git_item_line"
		num_line_items=$( wc -w <<< $git_item_line )
		if [ ! "$num_line_items" == "2" ]; then
			continue;
		fi
		git_items_array=($git_item_line)
		
		GIT_SHA=${git_items_array[0]}
		GIT_ITEM_NAME=${git_items_array[1]}

		echo " * Git item '${GIT_ITEM_NAME}' with sha=$GIT_SHA"
		processOneGitItem "$GIT_SHA" "$GIT_ITEM_NAME"


	done
}

# TODO: Remove non-existing branches

# Usage: $1=git_sha  $2=git_name
function processOneGitItem
{
	GIT_BRANCH=$2
	OUT_WWWDIR=$OUT_WWWROOT/$GIT_BRANCH

	SHA_CACHE_FILE=$OUT_WWWROOT/$GIT_BRANCH-last-git-update.sha
	DOCGEN_LOG_FILE=$OUT_WWWROOT/$GIT_BRANCH.log

	if [ ! -f $SHA_CACHE_FILE ]; then
                echo " " > $SHA_CACHE_FILE
        fi

	# Check if there are new commit(s)?
        CURSHA=$1
        LASTSHA=$(cat $SHA_CACHE_FILE)
	
        # Any change?
        if [ "$CURSHA" != "$LASTSHA" ]; then
                set -x
  	
		# Clone if it does not exist:
		if [ ! -d $GIT_CLONEDIR ]; then
			mkdir -p $GIT_CLONEDIR
			git clone $GIT_URI $GIT_CLONEDIR
		fi

		cd $GIT_CLONEDIR

		# Update and get the req branch:
		git clean -fd >/dev/null
		git checkout .  >/dev/null
	
		git fetch
		git checkout $GIT_BRANCH  > $DOCGEN_LOG_FILE 2>&1 2>&1

		# build docs:
		echo "Fails" > $DOCGEN_LOG_FILE.state
		set +e
		eval /usr/bin/time -f "%E" -o $DOCGEN_LOG_FILE.time $DOCGEN_CMD >> $DOCGEN_LOG_FILE 2>&1
		DOC_RETCODE=$?
		echo "DOCGEN return code: $DOC_RETCODE"
		set -e
		if [ "$DOC_RETCODE" -eq "0" ]; then
		        echo "Builds ok" > $DOCGEN_LOG_FILE.state

			# Copy to target WWW dir:
			mkdir -p $OUT_WWWDIR  >/dev/null 2>&1
			rsync -a $DOCGEN_OUT_DOC_DIR  $OUT_WWWDIR/  >/dev/null
			mv $GIT_CLONEDIR/doc/dox_mrpt.tag $OUT_WWWDIR/  || true
			chmod 755 $OUT_WWWDIR/ -R  >/dev/null  # required for doxygen search 
		fi

		# Clean up
		git clean -fd  >/dev/null
	
		# Save new commit sha:
		echo $CURSHA > $SHA_CACHE_FILE
	fi
}


mainGit2Docs

exit;



