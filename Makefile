HUGO ?= hugo
.PHONY: dev build post
dev:            ## Live preview incl. drafts at http://localhost:1313
	$(HUGO) server -D
build:          ## Production build into ./public
	$(HUGO) --gc --minify
post:           ## make post slug=my-new-post
	@test -n "$(slug)" || (echo 'usage: make post slug=my-new-post' && exit 1)
	$(HUGO) new content posts/$(slug).md
