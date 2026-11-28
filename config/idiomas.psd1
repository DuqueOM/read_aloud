#
# Lo que hay para cada idioma y para cada par de idiomas
# (docs\adr\0017-diccionario-en-el-panel.md, "Pensado para cualquier par de
# idiomas"). Hoy solo el diccionario del panel: las voces siguen en setup.ps1
# y los traductores en config\traduccion.psd1 hasta la fase 3 (paquetes de
# idiomas), que los agrega aqui, en el idioma o el par que les toca.
#
# setup.ps1 baja cada pieza de su origen, comprueba su sha256 y la deja en
# read_aloud_piper\diccionario\<Destino>. Nada de esto entra en el
# repositorio. Las piezas tienen el formato de config\traduccion.psd1, mas:
#
#   Formato     como se lee: 'wndb' (WordNet) o 'stardict'
#   Archivos    lo que tiene que traer la carpeta para que sirva
#   Excluir     archivos del zip que no se instalan
#   Licencia, Atribucion y Fuente: para la ventana, "Acerca de" y NOTICE
#
# Cada zip trae una sola carpeta, que queda con el nombre de Destino.
#
# Url puede empezar con el nombre de un origen entre llaves: se cambia en un
# solo lugar, en Origenes.

@{
    Origenes = @{
        # Una copia sin cambios de los zip de WikDict (CC BY-SA 4.0), con el
        # sha256 fijo: WikDict rearma sus archivos cada mes y no publica sumas.
        # Los de aqui son los del 26 nov 2026 (la fecha de su .ifo).
        DatosDiccionario = 'https://github.com/DuqueOM/read_aloud/releases/download/datos-diccionario-2026-11'
    }

    Idiomas = @{
        en = @{
            Definiciones = @{
                Id         = 'oewn2025'
                Url        = 'https://en-word.net/downloads/english-wordnet-2025.zip'
                Bytes      = 9616299
                Sha256     = '38b16326159f51853626b7d24a44c453fa88ab33f06fce5ec8fc5996d1c2be93'
                Destino    = 'oewn2025'
                Tipo       = 'zip'
                Formato    = 'wndb'
                Archivos   = @('index.noun', 'index.verb', 'index.adj', 'index.adv', 'data.noun', 'data.verb', 'data.adj', 'data.adv', 'noun.exc', 'verb.exc', 'adj.exc', 'adv.exc')
                # 6.5 MB que la busqueda no usa.
                Excluir    = @('index.sense')
                Licencia   = 'CC BY 4.0'
                Atribucion = 'Open English Wordnet is derived from Princeton WordNet by the Open English Wordnet Community'
                Fuente     = 'https://en-word.net'
            }
        }
        # Sin definiciones libres en el formato que se lee hoy.
        es = @{}
    }

    Pares = @{
        'en-es' = @{
            Bilingue = @{
                Id         = 'wikdict-en-es'
                Url        = '{DatosDiccionario}/wikdict-en-es.zip'
                Bytes      = 3673548
                Sha256     = 'd9ca6c453f286d7458a93465bb5caff5e515610647437467934c308dcc92b083'
                Destino    = 'wikdict-en-es'
                Tipo       = 'zip'
                Formato    = 'stardict'
                Archivos   = @('stardict.ifo', 'stardict.idx', 'stardict.dict')
                Excluir    = @()
                Licencia   = 'CC BY-SA 4.0'
                Atribucion = 'WikDict by Karl Bartel, from Wiktionary data via DBnary'
                Fuente     = 'https://www.wikdict.com'
            }
        }
        'es-en' = @{
            Bilingue = @{
                Id         = 'wikdict-es-en'
                Url        = '{DatosDiccionario}/wikdict-es-en.zip'
                Bytes      = 987049
                Sha256     = '883a8cd25c9ba918dc390abdcd676f8b8885f2f0ac685e4a2a0c5bd12fb4d9ea'
                Destino    = 'wikdict-es-en'
                Tipo       = 'zip'
                Formato    = 'stardict'
                Archivos   = @('stardict.ifo', 'stardict.idx', 'stardict.dict')
                Excluir    = @()
                Licencia   = 'CC BY-SA 4.0'
                Atribucion = 'WikDict by Karl Bartel, from Wiktionary data via DBnary'
                Fuente     = 'https://www.wikdict.com'
            }
            # es-en es chico (22 129 entradas, sin "orilla" ni "informe"): se
            # completa con el indice inverso del diccionario de en-es, que
            # setup.ps1 arma al instalar en diccionario\inverso\es-en.tsv.
            Inverso = 'en-es'
        }
    }
}
