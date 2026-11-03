# Pruebas

Pruebas con [Pester 5](https://pester.dev) de la parte del lector que no necesita
Piper, la tarjeta gráfica ni el proceso residente. Fijan lo que hace el código
hoy: si una falla después de un cambio, o el cambio rompió algo, o cambió la
lectura a propósito y hay que actualizar la prueba.

| Archivo | Qué prueba |
|---|---|
| `ReadAloud.Text.Tests.ps1` | `lib\ReadAloud.Text.ps1`: idioma, frases, diccionario, unidades, normalización, bloques y plan. |
| `ReadAloud.Core.Tests.ps1` | `lib\ReadAloud.Core.ps1`: rutas, capas de ajustes, elección del motor y lectura y alargado de WAV. |
| `SpeechPlan.Tests.ps1` | El plan completo de cada texto de `fixtures\textos` contra `fixtures\planes`, y una prueba de humo de `read_aloud.ps1 -ShowPlan`. |
| `Codificacion.Tests.ps1` | Que cada archivo de PowerShell tenga BOM o sea ASCII: Windows PowerShell 5.1 lee como ANSI los que no tienen BOM, y una tilde escrita tal cual llega cambiada al código. |

## Correrlas

Corren en Windows PowerShell 5.1, que es donde corre el lector, y también en
PowerShell 7. Pester 5 se instala una vez, en el usuario y sin permisos de
administrador (Windows trae Pester 3.4, que no sirve). PowerShell 7 guarda sus
módulos aparte, así que ahí se instala otra vez con el mismo comando:

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
```

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\run_pester.ps1
pwsh -NoProfile -File tools\run_pester.ps1
```

Con `-Resultados archivo.xml` guarda además los resultados en formato JUnit, como
en el CI.

## Planes de referencia

`fixtures\planes\<nombre>.txt` es el plan que da hoy `fixtures\textos\<nombre>.txt`:
por fragmento, el idioma, el bloque, el tipo, la pausa, lo que dice la voz y lo
que se muestra. Usan el diccionario de `config\terms_es.tsv`.

Cuando un cambio debe cambiar la lectura (una regla nueva del diccionario, por
ejemplo), se regeneran y se revisa el diff antes del commit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\actualizar_planes.ps1
git diff tests\fixtures\planes
```

Para probar un caso nuevo basta con agregar un `.txt` a `fixtures\textos` y
regenerar.
