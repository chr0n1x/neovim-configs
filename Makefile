default: packer-setup

# TODO: this is currently experimental. Packer.nvim does NOT support headless
#       package installation
packer-setup:
	nvim --headless -c 'autocmd User PackerComplete quitall' -c 'PackerSync'
	nvim --headless -c 'autocmd User PackerComplete quitall' -c 'PackerInstall'
	nvim --headless -c 'autocmd User COQdeps quitall'

# this is OPTIONAL to run. don't use this if you're managing your own symlinks
# via scripts or stow
link-configs:
	-mkdir ~/.config
	-ln -vs $(shell pwd) $(shell echo $$HOME)/.config/nvim

clean:
	rm -rf nvim/plugin ~/.local/share/nvim ~/.config/nvim ~/.cache/nvim


# need to be in elevated pems for this
# clone this repo into $HOME\AppData\Local\nvim
# run these first
#   winget install --id=Chocolatey.Chocolatey -e
#   choco install make
windows:
	choco install neovim fzf ripgrep python
