#!/usr/bin/env bash

JS_FILES=$(find . \
	-not \( -path './.git' -prune \) \
	-not \( -path './build' -prune \) \
	-not \( -path './node_modules' -prune \) \
	-not \( -path './public' -prune \) \
	-type f \
	\( -name '*.js' -or -name '*.jsx' \) \
)

if [ "$1" ]; then
	BRANCH=$1
else
	BRANCH=$(git rev-parse --abbrev-ref HEAD)
fi

if [ "$2" ]; then
	SHA=$1
fi

if [[ $BRANCH == "master" ]]; then
	exit 0
elif [[ $BRANCH == "HEAD" ]]; then
	exit 1
fi

if type "node" &> /dev/null; then
	cd gp-localci-client/i18n-calypso
	git submodule init; git submodule update
	npm install
	cd -
	node gp-localci-client/i18n-calypso/bin --format pot --output-file ./localci-js-changed.pot $JS_FILES
	git merge-base --fork-point master | xargs git checkout;
	node gp-localci-client/i18n-calypso/bin --format pot --output-file ./localci-js-master.pot $JS_FILES
	cp localci-js-master.pot localci-js-master-copy.pot;
fi

msgcat -u localci-*.pot > localci-new-strings.pot;
rm localci-*-master-copy.pot;

if [[ ${#SHA} -eq 40 ]]; then
	git checkout $SHA
else
	git checkout $BRANCH
fi
