# bor.re — Eduardo Hernández Cansino

Sitio personal bilingüe (ES/EN) construido con [Hugo](https://gohugo.io/) y el tema [PaperMod](https://github.com/adityatelange/hugo-PaperMod). Incluye páginas "Semblanza", blog, hub de links y página "Now", más automatizaciones para despliegues en Netlify o GitHub Pages.

## Arranque rápido
1. Instala Hugo (v0.109+). Comprueba con `hugo version`.
2. Clona el repositorio e inicializa el submódulo del tema: `git submodule update --init --recursive`.
3. Corre el servidor de desarrollo: `make dev` o `hugo server -D`.
4. Construye para producción cuando estés listo: `make build` (usa `HUGO_ENV=production`).

## Modelo de contenido
- `content/_index.*.md`: Hero y resumen inicial.
- `content/about/`: Biografías bilingües con pestañas, métricas y sección de "Speaking & Media".
- `content/blog/`: Entradas con taxonomías `cloud`, `AI & data`, `DevOps`, `leadership & mentorship`, `homelab`, `food-driven`.
- `content/links/`: Hub de redes sociales y recursos destacados.
- `content/now/`: Página "Now" actualizable.
- Cada archivo `.es.md` / `.en.md` funciona como par lingüístico; usa `lang` en el front matter cuando crees nuevos contenidos.

### Crear nuevas entradas bilingües
Usa `make new-post title="Nombre del post" lang=es|en`. El comando genera el archivo a partir de `archetypes/post.<lang>.md` y aplica slug automático. Repite para cada idioma y conecta las traducciones con el mismo `translationKey` si deseas enlazarlas manualmente.

## Personalizar la UI
- Ajusta parámetros globales en `hugo.toml` (`params.homeInfoParams`, menús por idioma, enlaces sociales, modo oscuro, etc.).
- Estilos adicionales en `assets/css/extended/custom.css` (lengua-tabs, tamaños de botones, etc.).
- La imagen de portada social y favicons viven en `static/images/`; reemplaza los marcadores `hero-placeholder.jpg` y `social-card.png` cuando tengas arte final.

## Integraciones y analítica
- Define `params.analytics.googleAnalyticsID` o variables de Plausible antes del despliegue.
- Actualiza los enlaces de redes si cambian (`LinkedIn`, `GitHub`, `X/Twitter`, `Instagram`).
- Revisa el `<TODO>` en `hugo.toml` para fijar `baseURL = "https://bor.re"` al publicar.

## Calidad y automatización
- Ejecuta `pre-commit install` para habilitar los ganchos (`markdownlint`, `cspell` ES/EN, validación de front matter vía Hugo).
- `Makefile` expone `make dev`, `make serve`, `make build`, `make new-post` y `make clean`.
- GitHub Actions (`.github/workflows/`) compila el sitio y puede publicar en GitHub Pages.

## Despliegue
### Netlify
- Usa el `netlify.toml` incluido (`build = "hugo --gc --minify"`, `publish = "public"`).
- Configura la variable `HUGO_VERSION` con la versión LTS más reciente y actualiza el dominio `bor.re` en el panel de Netlify.

### GitHub Pages
- El workflow `hugo-gh-pages.yml` construye el sitio y publica en la rama `gh-pages` usando GitHub Actions.
- Crea un token con permisos de `pages:write` si es necesario y habilita Pages desde la rama `gh-pages` en el repositorio.
- Se incluye `static/CNAME` con `bor.re` para los despliegues en Pages.

## TODOs antes de producción
- Sustituir imagen y favicon por la fotografía oficial.
- Ajustar identificadores reales de analítica (Google/Plausible).
- Confirmar usuarios definitivos de GitHub y X/Twitter si difieren de los placeholders.
