# git2docs
Generating docs for each Git tag &amp; branch, made easy

## Features
* Checks for updates in Git branches or new tags and generates their documentation. 
* Git SHA values are cached for each branch so documentation is only (re)built if necessary.
* Compatible with Doxygen, Sphinx and any other documentation tool.
* Generates a summary table for each branch with build time, success/error status, etc.
* Exposes a list of logs for each attempt to build documentation. Local path names are 
  replaced to avoid exposing information on machine local paths.
* Written in pure Bash. No dependencies. Install it anywhere.

Check out this [example output](http://mrpt.ual.es/reference/).

## Instalation

* Clone this repository. 
* Make a copy of the configuration template:

```bash
cp config.sh.template config.sh
```

* Edit `config.sh` to put the URI of your Git repository, etc. See all required parameters [here](https://github.com/jlblancoc/git2docs/blob/master/config.sh.template)

* Add a call to `bash [PATH_TO]/git2docs.sh` to your crontab if you want it to be executed periodically (e.g. on a hourly basis).

* You can also manually invoke `git2docs.sh`. To check that everything is working as expected, run it in versbose mode: 

```bash
VERBOSE=1 ./git2docs.sh
```
