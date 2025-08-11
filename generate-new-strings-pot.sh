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
	local PHP_FILE="$OUTPUT_DIR/localci-new-php-strings.pot"
	local JS_FILE="$OUTPUT_DIR/localci-new-strings.pot"
	if [[ -f "$PHP_FILE" ]]; then
		cat "$PHP_FILE" >> "$JS_FILE"
	fi
	rm -f "$PHP_FILE"
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
}

# Extract PHP strings from changed files. 
# This function collects new PHP strings from changed files in the current branch.
# It creates temporary PHP files for each new string and uses WP-CLI to extract the strings
# into a POT file. The headers of the POT file are cleaned up before output.
function extract_php_strings() {
	CHANGED_PHP_FILES=$(git diff --name-only $(git merge-base $BRANCH $DEFAULT_BRANCH) $BRANCH -- '*.php')
	LOCALCI_NEW_PHP_STRINGS=""
	if [ -n "$CHANGED_PHP_FILES" ]; then
		for PHP_FILE in $CHANGED_PHP_FILES; do
			if [ -f "$PHP_FILE" ]; then
				NEW_LINES=$(git diff $(git merge-base $BRANCH $DEFAULT_BRANCH) $BRANCH -- "$PHP_FILE" | grep '^+' | grep -v '^+++' | sed 's/^+//')
				if [ -n "$NEW_LINES" ]; then
					LOCALCI_NEW_PHP_STRINGS="${LOCALCI_NEW_PHP_STRINGS}${NEW_LINES}"$'\n\n\n\n\n\n'
				fi
			fi
		done

		if [ -n "$LOCALCI_NEW_PHP_STRINGS" ]; then
			mkdir -p "${OUTPUT_DIR}/files"
			LINE_NUMBER=1
			echo "$LOCALCI_NEW_PHP_STRINGS" | while IFS= read -r LINE; do
				if [ -z "$LINE" ]; then
					continue
				fi
				if [[ "$LINE" != *"<?php"* ]]; then
					LINE="<?php $LINE"
				fi
				file_path="${OUTPUT_DIR}/files/${LINE_NUMBER}.php"
				echo "$LINE" > "$file_path"
				LINE_NUMBER=$((LINE_NUMBER+1))
			done

			if command -v wp &> /dev/null; then
				echo $(pwd)
				wp i18n make-pot . "${OUTPUT_DIR}/localci-new-php-strings.pot" --include="${OUTPUT_DIR}/files/" --ignore-domain
				clean_pot_headers "${OUTPUT_DIR}/localci-new-php-strings.pot"
				echo "Extraction complete. Output: ${OUTPUT_DIR}/localci-new-php-strings.pot"
			else
				echo "WP-CLI not found. Cannot extract PHP translation strings."
			fi
			rm -rf "${OUTPUT_DIR}/files"
		fi
	fi
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
echo "CHANGED_FILES: $CHANGED_FILES"
echo "LINES: $LINES"

# remove throwaway file created by cross-platform sed command
rm -f localci-changed-files.json.bak

# convert CHANGED_FILES to single line input
CHANGED_FILES="$(tr '\n' ' ' <<<$CHANGED_FILES)"

# if node is installed, d/l node gettext tools and run
if type "npx" &> /dev/null; then
	npx @automattic/wp-babel-makepot "$CHANGED_FILES" -l localci-changed-files.json -d "./build/pot" -o ./localci-new-strings.pot
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

# Cleanup
rm -f localci-changed-files.json
rm -rf ./build/pot
move_pot_to_output

