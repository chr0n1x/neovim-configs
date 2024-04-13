My NeoVim Configs
====

Where I store my neovim customizations.

This is based on [my neovim template](https://github.com/chr0n1x/neovim-template) - start there or check out [my dotfiles repo](https://github.com/chr0n1x/dotfiles/tree/main/.config) to see how I manage this repo!

I split my neovim configs out into a separate repository to use as a submodule because I have two separate setups:
1. personal machine which is heavily based on the neovim-template linked above, primarily only FOSS plugins
2. work machine, where I have _extra_ configurations and many more work-related dependencies, copilot setup, etc

The goal of having a separate repo is so that I can manage the two configurations which pick & choose various plugins from the base template repo; the two setups are effectively forks of the original template, and constantly evolve based on changes in _each_ setup. The list & rate of changes that each setup goes through became too messy to deal with in my parent dotfiles repo sooooo here we are 😅
