# Arr Scripts

A collection of utility and maintenance scripts for the arr ecosystem.
Designed primarily for Unraid, but all of the scripts have fallbacks
for broader system support.

## Usage

Most scripts are standalone bash scripts that can be executed directly from the terminal,
scheduled via cron, or using the Unraid User Scripts plugin.

Configuration is handled by
- variables defined at the top of each script
- environment variables that can override those variables
- script will try to guess from the environment (e.g. Unraid user prefs)

Scripts that can edit or delete data have a `DRY_RUN` variable, you should
test your config thoroughly before setting `DRY_RUN=false`.
