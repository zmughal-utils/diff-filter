STOW_ARGS := -t $$HOME -d $$PWD/.. $$(basename $$PWD)

stow-dry-run:
	stow -n -v -S $(STOW_ARGS)
stow:
	stow -v -S $(STOW_ARGS)
