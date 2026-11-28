#
# Lo que setup.ps1 descarga para la traduccion (docs\adr\0016-traduccion-local.md).
# Todo se baja de su origen y se comprueba con sha256 antes de usarlo; si un
# archivo no coincide, no se instala. Nada de esto entra en el repositorio: va
# a read_aloud_piper\traduccion.
#
# Tipo: 'archivo' se copia tal cual, 'gz' se descomprime y 'zip' se extrae en
# la carpeta Destino. El sha256 es el del archivo descargado.
#
# translateLocally solo publica una version de prueba con la etiqueta
# "latest": si un dia cambia el archivo, el sha256 no coincide y la
# instalacion avisa y sigue sin la traduccion basica.

@{
    # Nivel basico: Bergamot (modelos base-memory de Mozilla, MPL 2.0) con
    # translateLocally (MIT). Unos 112 MB.
    Basica = @(
        @{
            Id      = 'translatelocally'
            Url     = 'https://github.com/XapaJIaMnu/translateLocally/releases/download/latest/translateLocally.windows-2022.core-avx-i.exe'
            Bytes   = 59515392
            Sha256  = 'b7cb0f58369cc508812f049af8c07ed59f2340e8007d31ee672dcef450e53aa4'
            Destino = 'translateLocally\translateLocally.exe'
            Tipo    = 'archivo'
        }
        @{
            Id      = 'bergamot-enes-modelo'
            Url     = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/en-es/retrain_hr_fix_names_CUAEXUHoQum_cFqh-ZAryw/exported/model.enes.intgemm.alphas.bin.gz'
            Bytes   = 22698792
            Sha256  = 'fe4025fde24a4d5f80533cfb7acd53d0eb7f194dfc2d8f427f0d4563cfb6ac06'
            Destino = 'translateLocally\models\en-es-base-memory\model.enes.intgemm.alphas.bin'
            Tipo    = 'gz'
        }
        @{
            Id      = 'bergamot-enes-lex'
            Url     = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/en-es/retrain_hr_fix_names_CUAEXUHoQum_cFqh-ZAryw/exported/lex.50.50.enes.s2t.bin.gz'
            Bytes   = 2265250
            Sha256  = '37a067966f28ff0ba430fddb7412bc5b07afa2cd2fd5a46d9ad74045a1a06380'
            Destino = 'translateLocally\models\en-es-base-memory\lex.50.50.enes.s2t.bin'
            Tipo    = 'gz'
        }
        @{
            Id      = 'bergamot-enes-vocab'
            Url     = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/en-es/retrain_hr_fix_names_CUAEXUHoQum_cFqh-ZAryw/exported/vocab.enes.spm.gz'
            Bytes   = 409312
            Sha256  = 'ae2760c04bc6eb5362b16e5c2f145c376bb04bac421c33ba3c0766805e6f03b3'
            Destino = 'translateLocally\models\en-es-base-memory\vocab.enes.spm'
            Tipo    = 'gz'
        }
        @{
            Id      = 'bergamot-esen-modelo'
            Url     = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/es-en/retrain_hr_HbNjJ60BTwmVTbhfFxuduA/exported/model.esen.intgemm.alphas.bin.gz'
            Bytes   = 23288494
            Sha256  = '54247f1e057180bca1d404dfd5c12836f65bc96cef7af98e59e55acb8bd093b1'
            Destino = 'translateLocally\models\es-en-base-memory\model.esen.intgemm.alphas.bin'
            Tipo    = 'gz'
        }
        @{
            Id      = 'bergamot-esen-lex'
            Url     = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/es-en/retrain_hr_HbNjJ60BTwmVTbhfFxuduA/exported/lex.50.50.esen.s2t.bin.gz'
            Bytes   = 2543246
            Sha256  = '3d7856bfa3b12804bdc80f12fd828fd9062c462113ab73fbf87c5c3b68420813'
            Destino = 'translateLocally\models\es-en-base-memory\lex.50.50.esen.s2t.bin'
            Tipo    = 'gz'
        }
        @{
            Id      = 'bergamot-esen-vocab'
            Url     = 'https://storage.googleapis.com/moz-fx-translations-data--303e-prod-translations-data/models/es-en/retrain_hr_HbNjJ60BTwmVTbhfFxuduA/exported/vocab.esen.spm.gz'
            Bytes   = 409312
            Sha256  = '1658b529b8858cf2e1e8cef2c4e2d69654d77b5f714ac52205864b336dfeb3ee'
            Destino = 'translateLocally\models\es-en-base-memory\vocab.esen.spm'
            Tipo    = 'gz'
        }
    )

    # Nivel alto: llama.cpp (MIT), la version Vulkan, que corre en la tarjeta de
    # cualquier marca y en el procesador, y Hy-MT2 1.8B de Tencent (Apache 2.0).
    # Unos 1.17 GB.
    Alta = @(
        @{
            Id      = 'llama-vulkan'
            Url     = 'https://github.com/ggml-org/llama.cpp/releases/download/b12780/llama-b12780-bin-win-vulkan-x64.zip'
            Bytes   = 39192861
            Sha256  = '113ab081025931f43f63e5adee78eccdecb2019dbe874a34a6a3e85e468db647'
            Destino = 'llama'
            Tipo    = 'zip'
        }
        @{
            Id      = 'hymt2-1.8b'
            Url     = 'https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/Hy-MT2-1.8B-Q4_K_M.gguf'
            Bytes   = 1133080448
            Sha256  = 'dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699'
            Destino = 'modelos\Hy-MT2-1.8B-Q4_K_M.gguf'
            Tipo    = 'archivo'
        }
    )

    # Hy-MT2 7B (Apache 2.0), para la prioridad de traduccion con la tarjeta
    # grafica. Necesita llama.cpp del nivel alto. 4.6 GB.
    Modelo7B = @(
        @{
            Id      = 'hymt2-7b'
            Url     = 'https://huggingface.co/tencent/Hy-MT2-7B-GGUF/resolve/main/Hy-MT2-7B-Q4_K_M.gguf'
            Bytes   = 4624648896
            Sha256  = '9f96256500f3fc1ab4d64336b58f52a949a95ad7516b0c229476eef782f9f77b'
            Destino = 'modelos\Hy-MT2-7B-Q4_K_M.gguf'
            Tipo    = 'archivo'
        }
    )
}
