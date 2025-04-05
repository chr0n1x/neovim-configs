clean:
	rm -rf nvim/plugin ~/.local/share/nvim ~/.config/nvim ~/.cache/nvim


# need to be in elevated pems for this
# clone this repo into $HOME\AppData\Local\nvim
# run these first
#   winget install --id=Chocolatey.Chocolatey -e
#   choco install make
windows:
	choco install neovim fzf ripgrep python
