#!/usr/bin/env bash

set -o errexit

# This script is intended to run on a branch.
# It generates default and branch pot files
# and then distills them to find the unique
# (new or changed) strings in the branch.

if [ -z "$DEFAULT_BRANCH" ]; then
	DEFAULT_BRANCH=$(git branch -al | grep HEAD | awk -F/ '{print $4}')
fi

if [[ "$1" ]]; then
	BRANCH=$1
else
	BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

if [[ "${#2}" -eq 40 ]]; then
	SHA=$2
fi

if [[ "$3" ]]; then
	OUTPUT_DIR=$3
fi

# bail if we don't have good branch information
if [[ "$BRANCH" == "$DEFAULT_BRANCH" ]]; then
	exit 0
elif [[ "$BRANCH" == "HEAD" ]]; then
	exit 1
fi

# Authenticated Github api requests
function auth_gh_curl() {
	local URL=$1;
	if [[ -n "${LOCALCI_APP_ID}" && -n "${LOCALCI_APP_SECRET}" ]] ; then
		AUTH="-u ${LOCALCI_APP_ID}:${LOCALCI_APP_SECRET}"
	fi
    curl -s $AUTH $URL
}

# Merge the PHP pot and JS the pot files in one file (the JS pot file).
function merge_php_js_pot_files() {
	local PHP_FILE="build/pot/localci-new-php-strings.pot"
	local JS_FILE="$OUTPUT_DIR/localci-new-strings.pot"
	if [[ -f "$PHP_FILE" ]]; then
		echo "" >> "$JS_FILE"
		cat "$PHP_FILE" >> "$JS_FILE"
	fi
}

function move_pot_to_output() {
	if [[ ! -f "./localci-new-strings.pot" ]]; then
		touch ./localci-new-strings.pot
	fi
	if [[ "$OUTPUT_DIR" ]]; then
		mkdir -p $OUTPUT_DIR
		mv localci-*.pot $OUTPUT_DIR
	fi
	merge_php_js_pot_files
	clean_files
}

# Extract PHP strings from changed files. 
# This function extracts PHP strings from the changed files in the current branch.
function extract_php_strings() {
	NEW_POT="build/pot/localci-new-branch-php-strings.pot"
	DEFAULT_POT="build/pot/localci-default-branch-php-strings.pot"
	OUTPUT_POT="build/pot/localci-new-php-strings.pot"
	git config pull.ff only
	git checkout $DEFAULT_BRANCH
#	git pull origin $DEFAULT_BRANCH
	echo "Current branch: $(git rev-parse --abbrev-ref HEAD)" 
	echo "SHA of the last commit of the $(git rev-parse --abbrev-ref HEAD) branch: $(git rev-parse HEAD)"
	git checkout $BRANCH
	echo "Current branch: $(git rev-parse --abbrev-ref HEAD)" 
	echo "Command to extract merge-base commit: git merge-base $BRANCH $DEFAULT_BRANCH. Result: $(git merge-base $BRANCH $DEFAULT_BRANCH)"
	COMMON_COMMIT_ANCESTOR=$(git merge-base $BRANCH $DEFAULT_BRANCH)
	echo "Command to extract changed files: git diff --name-only $COMMON_COMMIT_ANCESTOR $BRANCH -- '*.php'"
	echo -e "Changed PHP files:\n$(git diff --name-only $COMMON_COMMIT_ANCESTOR $BRANCH -- '*.php')"
	CHANGED_PHP_FILES=$(git diff --name-only $COMMON_COMMIT_ANCESTOR $BRANCH -- '*.php' | awk 'ORS=NR==0?"":", "' | sed 's/, $//')
	echo -e "List of changed PHP files:\n$CHANGED_PHP_FILES"

	git checkout $BRANCH
	echo "Current branch: $BRANCH"
	echo "Start the string extraction for new branch"
	if [ -n "$CHANGED_PHP_FILES" ]; then
		wp i18n make-pot . "$NEW_POT" --ignore-domain --skip-audit --include="$CHANGED_PHP_FILES" --debug
	else
		echo "No changed PHP files to extract."
		touch "$NEW_POT"
	fi
	echo "Cleaning up POT headers"
	clean_pot_headers "$NEW_POT"
	echo "Extraction complete. Output: $NEW_POT"
	git checkout $COMMON_COMMIT_ANCESTOR
	echo "Start the string extraction for default branch"
	if [ -n "$CHANGED_PHP_FILES" ]; then
		wp i18n make-pot . "$DEFAULT_POT" --ignore-domain --skip-audit --include="$CHANGED_PHP_FILES" --debug
	else
		echo "No changed PHP files to extract."
		touch "$DEFAULT_POT"
	fi
	echo "Cleaning up POT headers"
	clean_pot_headers "$DEFAULT_POT"
	echo "Extraction complete. Output: $DEFAULT_POT"


	# Truncate OUTPUT_POT to ensure it's a fresh file
	: > "$OUTPUT_POT"
	# Use awk to preserve comments and block structure, output only blocks in NEW_POT not in DEFAULT_POT
       awk -v new_pot="$NEW_POT" -v default_pot="$DEFAULT_POT" -v output_pot="$OUTPUT_POT" '
       BEGIN {
	       # Read all msgids from DEFAULT_POT into an array
	       while ((getline line < default_pot) > 0) {
		       if (line ~ /^msgid "/) {
			       msgid = substr(line, 8, length(line)-8)
			       in_msgid = 1
		       } else if (in_msgid && line ~ /^"/) {
			       msgid = msgid substr(line, 2, length(line)-2)
		       } else if (in_msgid && line !~ /^msgid / && line !~ /^"/) {
			       in_msgid = 0
			       default_ids[msgid] = 1
			       msgid = ""
		       }
	       }
	       if (msgid != "") default_ids[msgid] = 1
       }
       {
	       block = block $0 "\n"
	       if ($0 ~ /^msgid "/) {
		       msgid = substr($0, 8, length($0)-8)
		       in_msgid = 1
	       } else if (in_msgid && $0 ~ /^"/) {
		       msgid = msgid substr($0, 2, length($0)-2)
	       } else if (in_msgid && $0 !~ /^msgid / && $0 !~ /^"/) {
		       in_msgid = 0
	       }
	       if ($0 == "") {
		       if (msgid != "" && !(msgid in default_ids)) {
			       sub(/\n*$/, "", block); # remove trailing blank lines
			       printf "%s\n\n", block >> output_pot; # add exactly one blank line between blocks
		       }
		       block = ""
		       msgid = ""
	       }
       }
       END {
	       if (block != "" && msgid != "" && !(msgid in default_ids)) {
		       sub(/\n*$/, "", block); # remove trailing blank lines
		       printf "%s\n\n", block >> output_pot; # add exactly one blank line between blocks
	       }
       }
       ' "$NEW_POT"

       # clean_pot_headers "$OUTPUT_POT"
       echo "Diff extraction complete. Output: $OUTPUT_POT"

	git checkout $BRANCH
}

# Clean up headers from the POT file
clean_pot_headers() {
	local file="$1"
	sed -i.bak \
		-e '/^"Project-Id-Version:/d' \
		-e '/^"Report-Msgid-Bugs-To:/d' \
		-e '/^"Last-Translator:/d' \
		-e '/^"Language-Team:/d' \
		-e '/^"MIME-Version:/d' \
		-e '/^"Content-Type:/d' \
		-e '/^"Content-Transfer-Encoding:/d' \
		-e '/^"POT-Creation-Date:/d' \
		-e '/^"PO-Revision-Date:/d' \
		-e '/^"X-Generator:/d' \
		"$file"
	rm -f "${file}.bak"
}

# Cleanup function to remove temporary files
clean_files() {
	rm -rf ./build/pot
	rm -f localci-changed-files.json
}

# Files and hashes of changes in this Pull request/Branch
if [[ "$CI_PULL_REQUEST" ]]; then
	echo "LocalCI - processing pull request $CI_PULL_REQUEST"
	FILESURL=https://api.github.com/repos/$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME/pulls/${CI_PULL_REQUEST##*/}/files
	COMMITSURL=https://api.github.com/repos/$CIRCLE_PROJECT_USERNAME/$CIRCLE_PROJECT_REPONAME/pulls/${CI_PULL_REQUEST##*/}/commits
	echo "LocalCI - fetching $FILESURL"
	GH_FILESURL_CONTENT=$(auth_gh_curl $FILESURL)

	# Disable exit on error. This section checks for non-0 exit codes
	set +o errexit

	ANY_CHANGED_FILES=$(echo $GH_FILESURL_CONTENT | jq -r '.[] .filename' )
	if [ $? -ne 0 ]; then
	    echo "Error parsing $FILESURL:"
	    echo $GH_FILESURL_CONTENT
	fi

	CHANGED_FILES=$(echo "$ANY_CHANGED_FILES" | grep -e '.jsx$' -e '\.js$' -e '.tsx$' -e '\.ts$' )
	if [ $? -ne 0 ]; then
	    echo "No JS files changed."
	    exit 0
	fi

	echo "LocalCI - fetching $COMMITSURL"
	GH_COMMITSURL_CONTENT=$(auth_gh_curl $COMMITSURL)
	COMMITS_HASHES=$(echo $GH_COMMITSURL_CONTENT | jq -r '.[] .sha');
	if [ $? -ne 0 ]; then
	    echo "Error parsing $COMMITSURL:"
	    echo $GH_COMMITSURL_CONTENT
	fi

	# Re-enable exit on error
	set -o errexit

else
	echo "LocalCI - processing branch $BRANCH"
	extract_php_strings
	CHANGED_FILES=$(git diff --name-only $(git merge-base $BRANCH $DEFAULT_BRANCH) $BRANCH -- '*.js' '*.jsx' '*.ts' '*.tsx')
	COMMITS_HASHES=$(git log $DEFAULT_BRANCH..$BRANCH --pretty=format:%H);
	echo "Current branch: $(git rev-parse --abbrev-ref HEAD)"
	echo "Command to extract merge-base commit: git merge-base $BRANCH $DEFAULT_BRANCH. Result: $(git merge-base $BRANCH $DEFAULT_BRANCH)"
	echo "Command to extract changed files: git diff --name-only $(git merge-base $BRANCH $DEFAULT_BRANCH) $BRANCH -- '*.js' '*.jsx' '*.ts' '*.tsx'"
	echo -e "Changed files:\n$CHANGED_FILES"
	echo "Commits hashes: $COMMITS_HASHES"
fi

# Bail if no files were changed in this branch
if [ -z "$CHANGED_FILES" ]; then
	move_pot_to_output
	exit 0
fi

# Concatenate
function join_by { local d=$1; shift; echo -n "$1"; shift; printf "%s" "${@/#/$d}"; }
COMMITS_HASHES=$(join_by '\|^' ${COMMITS_HASHES[@]})

# Output our json file
printf "{" > localci-changed-files.json
for file in $CHANGED_FILES; do
	# No need to blame on a removed file
	if [ ! -f "$(pwd)/$file" ]; then
		continue
	fi
	# Get all the lines that changed in our commits
	LINES=$(git blame -flsp ${file} | grep "^${COMMITS_HASHES}" | cut -f 3 -d " ")
	if [ -n "$LINES" ]; then
		printf '"%s":[' "$file" >> localci-changed-files.json
		lastline=
		for line in $LINES ; do
			# Also add previous line, for cases where 'translate' is on one line, and the actual string on the next
			[[ "$lastline" -ne "$((line-1))" ]] && printf '%d,' $((line-1)) >> localci-changed-files.json
			printf '%d,' $line >> localci-changed-files.json
			lastline=$line
		done;
		sed -i.bak '$ s/,$/],/' localci-changed-files.json # replace last comma with closing square bracket and comma
	fi;
done;
sed -i.bak '$ s/,$//' localci-changed-files.json # remove last comma
printf '}\n' >> localci-changed-files.json

# remove throwaway file created by cross-platform sed command
rm -f localci-changed-files.json.bak

# convert CHANGED_FILES to single line input
CHANGED_FILES="$(tr '\n' ' ' <<<$CHANGED_FILES)"

# if node is installed, d/l node gettext tools and run
if type "npx" &> /dev/null; then
	echo "Running: npx --verbose @automattic/wp-babel-makepot \"$CHANGED_FILES\" -l localci-changed-files.json -d \"./build/pot\" -o ./localci-new-strings.pot"
	npx --verbose @automattic/wp-babel-makepot "$CHANGED_FILES" -l localci-changed-files.json -d "./build/pot" -o ./localci-new-strings.pot
	echo "localci-changed-files.json content: $(cat localci-changed-files.json)"
elif type "node" &> /dev/null; then
	cd gp-localci-client/i18n-calypso
	git submodule init; git submodule update
	npm install
	cd -
	node gp-localci-client/i18n-calypso/bin --format pot --lines-filter localci-changed-files.json -k translate,__,_x,_n,_nx -e date --output-file ./localci-new-strings.pot $CHANGED_FILES
else
	echo "npx and node not found.  Failed to extract strings."
	exit 1
fi

move_pot_to_output