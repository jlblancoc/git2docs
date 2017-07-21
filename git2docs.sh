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

function dbgEcho()
{
	if [ "$VERBOSE" == "1" ]; then
		echo "$1"
	fi
}

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

	dbgEcho "All git items:"
	dbgEcho "$LIST_GIT_ITEMS"

	declare -a git_lines
	readarray -t git_lines <<< "$LIST_GIT_ITEMS"

	# process each remote branch or tag
	for git_item_line in "${git_lines[@]}";
	do
		dbgEcho "Processing: $git_item_line"
		num_line_items=$( wc -w <<< $git_item_line )
		if [ ! "$num_line_items" == "2" ]; then
			continue;
		fi
		git_items_array=($git_item_line)

		GIT_SHA=${git_items_array[0]}
		GIT_ITEM_NAME=${git_items_array[1]}

		dbgEcho " * Git item '${GIT_ITEM_NAME}' with sha=$GIT_SHA"
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
		echo "Change detected in $GIT_BRANCH. Processing it."

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
		eval timeout $DOCGEN_TIMEOUT /usr/bin/time -f "%E" -o $DOCGEN_LOG_FILE.time $DOCGEN_CMD >> $DOCGEN_LOG_FILE 2>&1
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

		# Remove real path names from logs (for security reasons):
		# $GIT_CLONEDIR==> &laquo;SRC&raquo;
		# $OUT_WWWROOT ==> &laquo;OUT&raquo;
		sed -i -e "s=$GIT_CLONEDIR=«SRC»=g" $DOCGEN_LOG_FILE
                sed -i -e "s=$OUT_WWWROOT=«OUT»=g" $DOCGEN_LOG_FILE

		# Clean up
		git clean -fd  >/dev/null

		# Save new commit sha:
		echo $CURSHA > $SHA_CACHE_FILE
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
		\$("#git2logs_table").tablesorter();
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
		                echo "<tr>" >> $HTMLOUT
		                echo "   <td><a href=\"$dir\">$dir</a></td>" >> $HTMLOUT
		                echo "   <td>$(date +'%Y-%m-%d %T %z' -d @$(stat -c %Y $dir.log))</td>" >> $HTMLOUT
		                echo "   <td>$(cat $dir.log.state) (See <a href=\"$dir.log\" target='_blank'>log</a>, $(stat -c %s $dir.log | numfmt --to=iec-i --suffix B --format="%4f" ))<br/>" >> $HTMLOUT
				echo "Build duration: $(cat $dir.log.time). Dir size: $(du -sh $dir | cut -f 1)</td>" >> $HTMLOUT
        	                echo "   <td>$GITDATE" >> $HTMLOUT
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



