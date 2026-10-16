# eduardohc.cloud

Personal site and blog of Eduardo Hernández Cansino. Hugo (extended **0.150.0**) + PaperMod with a custom design layer, deployed to GitHub Pages on every push to `master` (`.github/workflows/pages.yml`).

## Setup
```bash
git clone --recurse-submodules git@github.com:Borre/borre-blog.git && cd borre-blog
hugo server -D          # http://localhost:1313
```

## Write a new post (one command)
```bash
hugo new content posts/my-post-slug.md     # or: make post slug=my-post-slug
```
Edit `content/posts/my-post-slug.md`, set `draft: false`, commit, push to `master` → live at `https://eduardohc.cloud/my-post-slug/` in ~1 minute.

Front matter: `title`, `date`, `description` (used for cards + social previews), `tags`, `featured: true` (pins to the home "Featured" row; otherwise the 3 latest show), optional `cover.image`.

## Structure
- `layouts/home.html` — home page (hero, featured, latest, topics). Hero text lives in `hugo.toml` → `[params.hero]`.
- `assets/css/extended/site.css` — all styling (light/dark tokens at the top).
- `layouts/_partials/extend_head.html` — fonts, social meta, Person JSON-LD.
- `content/about`, `content/now`, `content/links` — pages. `static/CNAME` = `eduardohc.cloud`.
- Permalinks are `/:slug/`; don't change them or old links break.
- RSS: `/index.xml` (also per tag: `/tags/<tag>/index.xml`).
