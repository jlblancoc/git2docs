#!/bin/bash
# ============================================================================
#  git2docs - Generating docs for each Git tag & branch, made easy
#  Copyright (C) 2017-2020 - Jose Luis Blanco Claraco
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

# Set to 1 to enable command echo
DEBUG_ENABLE_ECHO=${VERBOSE:-0}

set -e  # Exit on any error
#set -x # for debugging only

# User set-up:
MYDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"  # https://stackoverflow.com/a/246128/1631514
source $MYDIR/config.sh

if [ ! -f $OUT_WWWROOT ]; then
	mkdir -p $OUT_WWWROOT
fi

# Lock file preparation:
LOCKFILE=$OUT_WWWROOT/.git2docs.lock
DO_REMOVE_LOCK=1
# Make sure we cleanup lockfile on exit:
function cleanup
{
	if [ "$DO_REMOVE_LOCK" == "1" ]; then
		rm $LOCKFILE
	fi
}
trap cleanup EXIT

function remove_all_non_origin_branches
{
	cd $GIT_CLONEDIR
	DEFAULT_BRANCH=$(git remote show origin | grep "HEAD branch" | cut -d ":" -f 2)
	git merge --abort > /dev/null 2>&1  || true  # To clean up dirty repos
	git clean -xfd  > /dev/null
	git checkout .   > /dev/null
	git checkout $DEFAULT_BRANCH   > /dev/null 2>&1
	git fetch -p   > /dev/null
	for branch in `git branch -vv | grep ': gone]' | awk '{print $1}'`; do
		set -x
		git branch -D $branch   > /dev/null
		rm -fr $OUT_WWWROOT/$branch* || true
		set +x
	done
}


function dbgEcho()
{
	if [ "$VERBOSE" == "1" ]; then
		echo "$1"
	fi
}

# Use:: $1=Git URI
# Return the list of all remote branches AND tags
function getRemoteGitBranches
{
	GIT_LS_REM=$(git ls-remote $1 | grep -e "tags" -e "heads")
	RET=$(echo "$GIT_LS_REM" | grep -v -e "{}" | sed -e 's/\([0-9a-f]*\)\t\(refs\/\)\(heads\|tags\)\/\(.*\)/\1 \4/')

	echo "$RET"
}

function mainGit2Docs
{
	dbgEcho "Clearing non-remote branches:"
	remove_all_non_origin_branches

	dbgEcho "Getting list of git items:"
	LIST_GIT_ITEMS=$(getRemoteGitBranches $GIT_URI)

	dbgEcho "All git items:"
	dbgEcho "$LIST_GIT_ITEMS"

	declare -a git_lines
		readarray -t git_lines <<< "$LIST_GIT_ITEMS"

		# process each remote branch or tag
		LIST_GIT_RELEASES=()
		LIST_GIT_ITEMS=()
		for git_item_line in "${git_lines[@]}";
		do
			dbgEcho " * Processing... $git_item_line"
			num_line_items=$( wc -w <<< $git_item_line )
			if [ ! "$num_line_items" == "2" ]; then
				continue;
			fi
			git_items_array=($git_item_line)

			GIT_SHA=${git_items_array[0]}
			GIT_ITEM_NAME=${git_items_array[1]}

			# add list of numeric versions:
			if [[ $GIT_ITEM_NAME =~ ^v*[0-9]+.* ]]; then
				LIST_GIT_RELEASES+=($GIT_ITEM_NAME)
			fi
			LIST_GIT_ITEMS+=($GIT_ITEM_NAME)

			dbgEcho "  * Git item: '${GIT_ITEM_NAME}'"
			dbgEcho "  * Git SHA : $GIT_SHA"
			processOneGitItem "$GIT_SHA" "$GIT_ITEM_NAME"
		done

		# If we have 1 or more "v1.2.3" or "1.2.3" tags (releases), sort them
		# and assume the latest one is "stable":
		if [ ! ${#LIST_GIT_RELEASES[@]} -eq 0 ];
		then
			dbgEcho ${LIST_GIT_RELEASES[@]}
			IFS=$'\n' SORTED_LIST_GIT_ITEMS=($(sort -V <<<"${LIST_GIT_RELEASES[*]}"))
			unset IFS

			LAST_GIT_RELEASE=${SORTED_LIST_GIT_ITEMS[-1]}
			dbgEcho "* Creating 'stable' symlink for latest release: '$LAST_GIT_RELEASE'"

			rm $OUT_WWWROOT/stable 2>/dev/null || true
			ln -s $OUT_WWWROOT/$LAST_GIT_RELEASE $OUT_WWWROOT/stable
		fi

		# TO-DO: Remove non-existing branches

}


# Usage: $1=git_sha  $2=git_name
function processOneGitItem
{
	GIT_BRANCH=$2
	GIT_BRANCH_CLEAN=$(echo $GIT_BRANCH | sed -e 's/\//_/g')
	OUT_WWWDIR=$OUT_WWWROOT/$GIT_BRANCH_CLEAN

	SHA_CACHE_FILE=$OUT_WWWROOT/$GIT_BRANCH_CLEAN-last-git-update.sha
	DOCGEN_LOG_FILE=$OUT_WWWROOT/$GIT_BRANCH_CLEAN.log
	if [ ! -f $SHA_CACHE_FILE ]; then
		echo " " > $SHA_CACHE_FILE
	fi

	# Check if there are new commit(s)?
	CURSHA=$1
	LASTSHA=$(cat $SHA_CACHE_FILE)

	# Any change?
	if [ "$CURSHA" != "$LASTSHA" ]; then
		if [ ! $DEBUG_ENABLE_ECHO -eq 0 ];then
			set -x
		fi
		echo "  => Change detected in '$GIT_BRANCH'. SHA: '$LASTSHA'->'$CURSHA'. Processing it."
		echo "" > $DOCGEN_LOG_FILE # Reset log file

		# Clone if it does not exist:
		if [ ! -d $GIT_CLONEDIR ]; then
			mkdir -p $GIT_CLONEDIR
			git clone $GIT_URI $GIT_CLONEDIR
		fi

		cd $GIT_CLONEDIR

		# Update and get the req branch:
		git clean -xfd >/dev/null
		git pull --all --force > /dev/null 2>&1 || true
		git checkout .  >/dev/null
		git branch -D $GIT_BRANCH > /dev/null 2>&1 || true  # to prevent errors after "force-push"es
		git checkout $GIT_BRANCH  >> $DOCGEN_LOG_FILE 2>&1
		# only if we are in a branch (as opposed to a tag), do a pull:
		IS_BRANCH=0
		git describe --exact-match --tags HEAD 2>/dev/null || IS_BRANCH=1

		if [ "$IS_BRANCH" -eq "1" ]; then
			dbgEcho "Git item: '$GIT_BRANCH' is a branch."
			git pull --force  >> $DOCGEN_LOG_FILE 2>&1
		else
			dbgEcho "Git item: '$GIT_BRANCH' is a tag."
		fi

                # Save new commit sha:
		echo "   Saving new SHA to cache file: '$SHA_CACHE_FILE'"
		echo $CURSHA > $SHA_CACHE_FILE

		# build docs:
		echo "Fails" > $DOCGEN_LOG_FILE.state
		set +e
		if [ "$GIT2DOCS_DRY_RUN" != "1" ]; then
			eval timeout $DOCGEN_TIMEOUT /usr/bin/time -f "%E" -o $DOCGEN_LOG_FILE.time $DOCGEN_CMD >> $DOCGEN_LOG_FILE 2>&1
		else
			echo "DRY RUN, DOING NOTHING..."
		fi
		DOC_RETCODE=$?
		echo "DOCGEN return code: $DOC_RETCODE"
		set -e
		if [ "$DOC_RETCODE" -eq "0" ]; then
		       	echo "Builds ok" > $DOCGEN_LOG_FILE.state
			# Copy to target WWW dir:
			mkdir -p $OUT_WWWDIR  >/dev/null 2>&1
			rsync -a --delete $DOCGEN_OUT_DOC_DIR  $OUT_WWWDIR/ >/dev/null || echo "==WARNING== Ignoring error in rsync!"

			if stat --printf='' $GIT_CLONEDIR/doc/*.tag 2>/dev/null
			then
				mv $GIT_CLONEDIR/doc/*.tag $OUT_WWWDIR/
			fi
			chmod 755 $OUT_WWWDIR/ -R  >/dev/null  # required for doxygen search
		fi

		# Remove real path names from logs (for security reasons):
		# $GIT_CLONEDIR==> &laquo;SRC&raquo;
		# $OUT_WWWROOT ==> &laquo;OUT&raquo;
		sed -i -e "s=$GIT_CLONEDIR=«SRC»=g" $DOCGEN_LOG_FILE
                sed -i -e "s=$OUT_WWWROOT=«OUT»=g" $DOCGEN_LOG_FILE
		# Clean up
		git clean -xfd  >/dev/null
	else
		dbgEcho "  => No changes detected."
fi
}

# Parse all the files generated by mainGit2Docs() and creates an HTML index.
function generateIndex
{
	HTMLOUT=$OUT_WWWROOT/index.html
	GIT_URI_COMMITS=$(echo $GIT_URI | sed 's/\.git//g')

	cat > $HTMLOUT <<- EOM
<!DOCTYPE html>
<html>
 <head>
  <title>Index - Git2Doc</title>
  <style type="text/css">
    table, tr, td {
	border: 1px solid black;
    }
    table th {
        text-decoration : underline;
        color: #666;
    }
    table th:hover {
        color: black;
    }
  </style>
  <script type="text/javascript" src="js/jquery-latest.min.js"></script>
  <script type="text/javascript" src="js/jquery.tablesorter.js"></script>
  <script>
   \$(document).ready(function()
	{
		console.log( "document loaded" );
		\$("#git2logs_table").tablesorter(  {sortList: [ [3,1] ]} );
	}
	);
  </script>
EOM
	if [ -f "$MYDIR/$HTML_EXTRA_HEAD" ]; then
		dbgEcho "Including in HTML <head>: $MYDIR/$HTML_PAGE_HEADER"
		cat $MYDIR/$HTML_EXTRA_HEAD >> $HTMLOUT
	fi

	cat >> $HTMLOUT <<-EOM
 </head>
 <body>
EOM

        if [ -f "$MYDIR/$HTML_PAGE_HEADER" ]; then
		dbgEcho "Including in HTML body (header): $MYDIR/$HTML_PAGE_HEADER"
                cat $MYDIR/$HTML_PAGE_HEADER >> $HTMLOUT
        fi

	cat >> $HTMLOUT <<-EOM
 <div style='text-align: center;'>
 <table id="git2logs_table" class="tablesorter tablesorter-blue" cellpadding=5 cellspacing=0 align='center'>
 <thead>
  <tr>
   <td><b>Branch/tag name</b></td>
   <td><b>Last docs build</b></td>
   <td><b>Docs build info</b></td>
   <td><b>Git commit</b></td>
  </tr>
 </thead>
 <tbody>
EOM
	UNIXDATE_NOW=$(date +"%s")
	cd $OUT_WWWROOT
	for dir in $(ls */ -d1c | cut -f 1 -d "/")
	do
		if [ -L "$dir" ]; then
	                echo "<tr>" >> $HTMLOUT
	                echo "   <td colspan="5"><a href=\"$dir\">$dir</a> (&rightarrow; $(basename $(readlink -f $dir)))</td>" >> $HTMLOUT
		else
			if [ -f "$dir.log" ]; then
				GITSHA=$(cat $dir-last-git-update.sha)
				GITDATE=$(cd $GIT_CLONEDIR && git log -1 --format=%ci $GITSHA)
				UNIXDATE_GIT=$(cd $GIT_CLONEDIR && git log -1 --format=%ct $GITSHA)
				GIT_AGE=$(($UNIXDATE_NOW - $UNIXDATE_GIT))

                                if ((GIT_AGE < $((7*24*60*60)) )); then
					IS_RECENT=1
				else
					IS_RECENT=0
				fi

		                echo "<tr>" >> $HTMLOUT
		                echo "   <td><a href=\"$dir\">$dir</a></td>" >> $HTMLOUT
		                echo "   <td>$(date +'%Y-%m-%d %T %z' -d @$(stat -c %Y $dir.log))</td>" >> $HTMLOUT
		                echo "   <td>$(cat $dir.log.state) (See <a href=\"$dir.log\" target='_blank'>log</a>, $(stat -c %s $dir.log | numfmt --to=iec-i --suffix B --format="%4f" ))<br/>" >> $HTMLOUT
				echo "Build duration: $(cat $dir.log.time). Dir size: $(du -sh $dir | cut -f 1)</td>" >> $HTMLOUT

				# git age:
        	                echo "   <td>" >> $HTMLOUT

				if [ $IS_RECENT == "1" ]; then
					echo "<b>" >> $HTMLOUT
				fi
				echo "$GITDATE" >> $HTMLOUT
				if [ $IS_RECENT == "1" ]; then
                                        echo "</b>" >> $HTMLOUT
                                fi
   				echo " (<a href="$GIT_URI_COMMITS/commit/$(cat $dir-last-git-update.sha)">$(cat $dir-last-git-update.sha | cut -c1-7)</a>)</td>" >> $HTMLOUT

	        	        echo "  </tr>" >> $HTMLOUT
			fi
		fi
	done

cat >> $HTMLOUT <<- EOM
 </tbody>
 </table>
 </div>
EOM

	if [ -f "$MYDIR/$HTML_PAGE_FOOTER" ]; then
                cat $MYDIR/$HTML_PAGE_FOOTER >> $HTMLOUT
	fi

	cat >> $HTMLOUT <<-EOM
<p>&nbsp;</p>
<hr>
<small>Generated on $(date +%c) by <a href="https://github.com/jlblancoc/git2docs">Git2Docs</a></small>

 </body>
 </html>
EOM
}

# Check for another active session:
if [ -f $LOCKFILE ]; then
	# There is a lock file. Honor it and exit... unless it's really old,
	# which might indicate a dangling script (?).
	if [ "$(( $(date +"%s") - $(stat -c "%Y" $LOCKFILE) ))" -gt "3600" ]; then
		# too old: reset lock file
		rm $LOCKFILE
		dbgEcho "Removing dangling lockfile."
	else
		DO_REMOVE_LOCK=0
		dbgEcho "Exiting: there is another instance running? (lockfile exists)"
		exit;
	fi
fi
# Create lock file:
touch $LOCKFILE

# Ok, run git2docs:
mainGit2Docs
generateIndex

exit;
