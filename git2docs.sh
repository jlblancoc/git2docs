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
	git checkout . > /dev/null 2>&1
	git checkout $DEFAULT_BRANCH > /dev/null 2>&1
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

			# Skip items not in the allowlist (if one is defined):
			if [ ${#GIT2DOCS_ITEMS_ALLOWLIST[@]} -gt 0 ]; then
				ALLOWED=0
				for allowed_item in "${GIT2DOCS_ITEMS_ALLOWLIST[@]}"; do
					if [ "$GIT_ITEM_NAME" == "$allowed_item" ]; then
						ALLOWED=1
						break
					fi
				done
				if [ "$ALLOWED" -eq 0 ]; then
					dbgEcho "  * Skipping '${GIT_ITEM_NAME}' (not in GIT2DOCS_ITEMS_ALLOWLIST)"
					continue
				fi
			fi

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

	# TO-DO: Remove directories of non-existing branches.

	dbgEcho "End of mainGit2Docs()"
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
		git fetch --all --force --tags > /dev/null 2>&1 || true
		git checkout .  >/dev/null 2>&1
		git branch -D $GIT_BRANCH > /dev/null 2>&1 || true  # to prevent errors after "force-push"es
		if ! git checkout $GIT_BRANCH  >> $DOCGEN_LOG_FILE 2>&1; then
			echo "ERROR: git checkout '$GIT_BRANCH' failed. Re-cloning..." | tee -a $DOCGEN_LOG_FILE
			cd /
			rm -rf $GIT_CLONEDIR
			mkdir -p $GIT_CLONEDIR
			git clone $GIT_URI $GIT_CLONEDIR >> $DOCGEN_LOG_FILE 2>&1
			cd $GIT_CLONEDIR
			git checkout $GIT_BRANCH  >> $DOCGEN_LOG_FILE 2>&1
		fi
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
		echo "<p style=\"color:red\"><strong>Fails</strong></p>" > $DOCGEN_LOG_FILE.state
		set +e
		if [ "$GIT2DOCS_DRY_RUN" != "1" ]; then
			printf "===== GIT2DOCS: Starting build job at: $(date) ======\n\n" >> $DOCGEN_LOG_FILE
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

	cat > $HTMLOUT <<- 'EOM'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Documentation Index</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      background: #f5f7fa;
      color: #1a1a2e;
      min-height: 100vh;
    }

    .page-wrap {
      max-width: 1100px;
      margin: 0 auto;
      padding: 2rem 1.5rem 4rem;
    }

    .page-footer {
      text-align: center;
      margin-top: 2.5rem;
      font-size: 0.8rem;
      color: #888;
    }
    .page-footer a { color: #888; }
    .page-footer a:hover { color: #555; }

    .docs-table-wrap {
      background: #fff;
      border-radius: 12px;
      box-shadow: 0 2px 12px rgba(0,0,0,.08);
      overflow: hidden;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.92rem;
    }

    thead tr {
      background: #1a1a2e;
      color: #c8d0e0;
      font-size: 0.78rem;
      letter-spacing: .06em;
      text-transform: uppercase;
    }

    thead th {
      padding: .85rem 1.1rem;
      font-weight: 600;
      text-align: left;
      cursor: pointer;
      user-select: none;
      white-space: nowrap;
    }
    thead th:hover { color: #fff; }
    thead th.sort-asc::after  { content: " \25B2"; opacity: .7; }
    thead th.sort-desc::after { content: " \25BC"; opacity: .7; }

    tbody tr {
      border-bottom: 1px solid #eef0f4;
      transition: background .12s;
    }
    tbody tr:last-child { border-bottom: none; }
    tbody tr:hover { background: #f8f9fc; }

    td { padding: .75rem 1.1rem; vertical-align: middle; }

    .col-name a {
      font-weight: 600;
      color: #2563eb;
      text-decoration: none;
      font-size: 1rem;
    }
    .col-name a:hover { text-decoration: underline; }

    .badge {
      display: inline-block;
      font-size: 0.68rem;
      font-weight: 700;
      letter-spacing: .04em;
      padding: .18em .55em;
      border-radius: 999px;
      vertical-align: middle;
      margin-left: .4em;
      text-transform: uppercase;
    }
    .badge-alias  { background: #e0e7ff; color: #3730a3; }
    .badge-recent { background: #dcfce7; color: #166534; }

    .status-ok   { color: #16a34a; font-weight: 600; }
    .status-fail { color: #dc2626; font-weight: 600; }

    tr.alias-row td { color: #555; font-style: italic; }
    tr.alias-row a  { color: #2563eb; text-decoration: none; }
    tr.alias-row a:hover { text-decoration: underline; }

    .mono {
      font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
      font-size: 0.85em;
    }
    .muted     { color: #6b7280; font-size: 0.85em; }
    a.log-link { color: #6b7280; font-size: 0.82em; }
    a.log-link:hover { color: #2563eb; }
    a.sha-link { color: #6b7280; text-decoration: none; }
    a.sha-link:hover { color: #2563eb; text-decoration: underline; }
  </style>
  <script>
  document.addEventListener('DOMContentLoaded', function() {
    var table = document.getElementById('docs-table');
    if (!table) return;
    var headers = table.querySelectorAll('thead th[data-col]');
    var sortState = { col: null, dir: 1 };
    headers.forEach(function(th) {
      th.addEventListener('click', function() {
        var col = parseInt(th.getAttribute('data-col'));
        if (sortState.col === col) { sortState.dir *= -1; } else { sortState.col = col; sortState.dir = 1; }
        headers.forEach(function(h) { h.classList.remove('sort-asc','sort-desc'); });
        th.classList.add(sortState.dir === 1 ? 'sort-asc' : 'sort-desc');
        var tbody = table.querySelector('tbody');
        var rows = Array.from(tbody.querySelectorAll('tr'));
        rows.sort(function(a, b) {
          var ca = (a.children[col] || a.children[0]).getAttribute('data-sort') || (a.children[col] || a.children[0]).textContent;
          var cb = (b.children[col] || b.children[0]).getAttribute('data-sort') || (b.children[col] || b.children[0]).textContent;
          return ca < cb ? -sortState.dir : ca > cb ? sortState.dir : 0;
        });
        rows.forEach(function(r) { tbody.appendChild(r); });
      });
    });
  });
  </script>
EOM

	if [ -f "$MYDIR/$HTML_EXTRA_HEAD" ]; then
		dbgEcho "Including in HTML <head>: $MYDIR/$HTML_EXTRA_HEAD"
		cat $MYDIR/$HTML_EXTRA_HEAD >> $HTMLOUT
	fi

	cat >> $HTMLOUT <<-EOM
</head>
<body>
<div class="page-wrap">
EOM

	if [ -f "$MYDIR/$HTML_PAGE_HEADER" ]; then
		dbgEcho "Including in HTML body (header): $MYDIR/$HTML_PAGE_HEADER"
		cat $MYDIR/$HTML_PAGE_HEADER >> $HTMLOUT
	fi

	cat >> $HTMLOUT <<-EOM
<div class="docs-table-wrap">
<table id="docs-table">
<thead>
  <tr>
    <th data-col="0">Branch / Tag</th>
    <th data-col="1">Last build</th>
    <th data-col="2">Status</th>
    <th data-col="3">Git commit date</th>
    <th data-col="4">Commit</th>
  </tr>
</thead>
<tbody>
EOM

	UNIXDATE_NOW=$(date +"%s")
	cd $OUT_WWWROOT
	for dir in $(ls */ -d1c | cut -f 1 -d "/")
	do
		# symlink (alias)?
		if [ -L "$dir" ]; then
			ALIAS_TARGET=$(basename $(readlink -f $dir))
			echo "<tr class=\"alias-row\">" >> $HTMLOUT
			echo "  <td colspan=\"5\"><a href=\"$dir\">$dir</a><span class=\"badge badge-alias\">alias</span> &rarr; <a href=\"$ALIAS_TARGET\">$ALIAS_TARGET</a></td>" >> $HTMLOUT
			echo "</tr>" >> $HTMLOUT
		else
			# Regular directory — only if the log file exists.
			# (Directories can be left without a .log to be silently ignored.)
			if [ -f "$dir.log" ]; then
				dbgEcho "Processing table, row: $dir"
				GITSHA=$(cat $dir-last-git-update.sha)
				BUILD_DATE=$(date +'%Y-%m-%d %H:%M %z' -d @$(stat -c %Y $dir.log))
				BUILD_DATE_SORT=$(stat -c %Y $dir.log)
				BUILD_STATE=$(cat $dir.log.state 2>/dev/null || echo "unknown")
				BUILD_SIZE=$(stat -c %s $dir.log | numfmt --to=iec-i --suffix=B --format="%4f")
				BUILD_TIME=$(cat $dir.log.time 2>/dev/null || echo "—")
				DIR_SIZE=$(du -sh $dir | cut -f 1)
				GITDATE_ABS=$(cd $GIT_CLONEDIR && git log -1 --format=%cd --date=format:'%Y-%m-%d %H:%M' $GITSHA 2>/dev/null || echo "unknown")
				GITDATE_REL=$(cd $GIT_CLONEDIR && git log -1 --format=%cd --date=relative $GITSHA 2>/dev/null || echo "")
				UNIXDATE_GIT=$(cd $GIT_CLONEDIR && git log -1 --format=%ct $GITSHA 2>/dev/null || echo "0")
				GIT_AGE=$(($UNIXDATE_NOW - $UNIXDATE_GIT))

				if ((GIT_AGE < $((7*24*60*60)) )); then
					RECENT_BADGE="<span class=\"badge badge-recent\">new</span>"
				else
					RECENT_BADGE=""
				fi

				if echo "$BUILD_STATE" | grep -qi "ok\|success"; then
					STATUS_HTML="<span class=\"status-ok\">&#10003; OK</span>"
				else
					STATUS_HTML="<span class=\"status-fail\">&#10007; Failed</span>"
				fi

				echo "<tr>" >> $HTMLOUT
				echo "  <td class=\"col-name\" data-sort=\"$dir\"><a href=\"$dir\">$dir</a>${RECENT_BADGE}</td>" >> $HTMLOUT
				echo "  <td data-sort=\"$BUILD_DATE_SORT\">$BUILD_DATE<br><span class=\"muted\">duration: $BUILD_TIME &nbsp;|&nbsp; $DIR_SIZE</span></td>" >> $HTMLOUT
				echo "  <td>$STATUS_HTML<br><a class=\"log-link\" href=\"$dir.log\" target=\"_blank\">&#128196; log ($BUILD_SIZE)</a></td>" >> $HTMLOUT
				echo "  <td data-sort=\"$UNIXDATE_GIT\">$GITDATE_ABS<br><span class=\"muted\">$GITDATE_REL</span></td>" >> $HTMLOUT
				echo "  <td><a class=\"sha-link mono\" href=\"$GIT_URI_COMMITS/commit/$GITSHA\" target=\"_blank\">$(echo $GITSHA | cut -c1-7)</a></td>" >> $HTMLOUT
				echo "</tr>" >> $HTMLOUT
			fi
		fi
	done

	cat >> $HTMLOUT <<-EOM
</tbody>
</table>
</div>
EOM

	if [ -f "$MYDIR/$HTML_PAGE_FOOTER" ]; then
		cat $MYDIR/$HTML_PAGE_FOOTER >> $HTMLOUT
	fi

	cat >> $HTMLOUT <<-EOM
<p class="page-footer">Generated on $(date +'%Y-%m-%d %H:%M %Z') &mdash; <a href="https://github.com/jlblancoc/git2docs">Git2Docs</a></p>
</div>
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
