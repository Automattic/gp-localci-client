#!/usr/bin/env bash

# This script is intended to run on a branch.
# It generates master and branch pot files
# and then distills them to find the unique
# (new or changed) strings in the branch.

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
if [[ "$BRANCH" == "master" ]]; then
	exit 0
elif [[ "$BRANCH" == "HEAD" ]]; then
	exit 1
fi

function join_by { local d=$1; shift; echo -n "$1"; shift; printf "%s" "${@/#/$d}"; }

# All files changed in this branch
CHANGED_FILES=$(git diff --name-only $(git merge-base $BRANCH master) $BRANCH -- '*.js' '*.jsx')

# Diff commits to this branch
COMMITS_HASHES=$(git log master..$BRANCH --pretty=format:%H);

# Concatenate
COMMITS_HASHES=$(join_by '\|^' ${COMMITS_HASHES[@]})

# Output our json file
printf "{\n" > localci-changed-files.json
for file in $CHANGED_FILES; do
	# No need to blame on a removed file
	if [ ! -f "$(pwd)/$file" ]; then
		break
	fi
	# Get all the lines that changed in our commits
	LINES=$(git blame -flsp ${file} | grep "^${COMMITS_HASHES}" | cut -f 2 -d " ")
	if [ -n "$LINES" ]; then
		printf '"%s":[' "$file" >> localci-changed-files.json
		lastline=
		for line in $LINES ; do
			# Also add previous line, for cases where 'translate' is on one line, and the actual string on the next
			[[ "$lastline" -ne "$((line-1))" ]] && printf '%d,' $((line-1)) >> localci-changed-files.json
			printf '%d,' $line >> localci-changed-files.json
			lastline=$line
		done;
		sed -i '' '$ s/,$/],/' localci-changed-files.json # remove last comma
	fi;
done;
sed -i '' '$ s/,$//' localci-changed-files.json # remove last comma
printf '}\n' >> localci-changed-files.json

# if node is installed, d/l node gettext tools and run
if type "node" &> /dev/null; then
	LOCALCI_CLIENT_DIR=$(dirname $0)/i18n-calypso
	cd $LOCALCI_CLIENT_DIR
	git submodule init; git submodule update
	npm install
	cd -
	node $LOCALCI_CLIENT_DIR/bin --format pot --lines-filter localci-changed-files.json --output-file ./localci-new-strings.pot $CHANGED_FILES
fi

# Cleanup
rm -f localci-changed-files.json

if [[ "$OUTPUT_DIR" ]]; then
	mkdir -p $OUTPUT_DIR
	mv localci-*.pot $OUTPUT_DIR
fi
