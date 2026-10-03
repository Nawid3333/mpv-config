"""The chains under test. Each is a function of the display ratio (a key of
common.SIZES), so it can do what gpu-toggles.lua does: pick passes and the
sharpening strength by the real scale. 'movie' and 'anime' are the SHIPPED
presets - keep them in step with gpu-toggles.lua. The rest are the candidates
measured on 2026-10-03 (doc/history/sessions-2026-10.md), kept so a later
benchmark (a new libplacebo, a new model) is one command."""
from common import RATIO

EWA_D = ['--dscale=ewa_lanczossharp']


def auto_sharp(r):
    # gpu-toggles.lua effective_sharpness(): scale - 1, clamped to 0.5..1.5
    return max(0.5, min(1.5, RATIO[r] - 1))


def sharpen(v):
    return ['--glsl-shader-opts=adaptive-sharpen/curve_height=%.3f' % v]


ANIME = ['Anime4K_Clamp_Highlights.glsl', 'Anime4K_Upscale_Denoise_CNN_x2_VL.glsl',
         'Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl',
         'Anime4K_Restore_CNN_M.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl']


def movie(r, sharp=True):
    sh = (['FSRCNNX_x2_16-0-4-1.glsl'] if RATIO[r] >= 2 else []) + ['SSimSuperRes.glsl', 'CfL_Prediction.glsl']
    if sharp:
        return {'shaders': sh + ['adaptive-sharpen.glsl'], 'opts': EWA_D + sharpen(auto_sharp(r))}
    return {'shaders': sh, 'opts': EWA_D}


def single(name, extra=()):
    return lambda r: {'shaders': list(extra) + [name], 'opts': EWA_D}


def anime4k(first, restore, second, adp=True, opts=()):
    sh = ['Anime4K_Clamp_Highlights.glsl', first]
    if adp:
        sh += ['Anime4K_AutoDownscalePre_x2.glsl', 'Anime4K_AutoDownscalePre_x4.glsl']
    return lambda r: {'shaders': sh + [restore, second], 'opts': list(opts)}


CHAINS = {
    # no shaders: mpv's own scalers (profile=high-quality)
    'off': lambda r: {},
    # the shipped presets (gpu-toggles.lua)
    'movie': movie,
    'movie_nosharp': lambda r: movie(r, sharp=False),
    'anime': lambda r: {'shaders': list(ANIME)},
    # chroma alone
    'cfl': single('CfL_Prediction.glsl'),
    'krig': single('KrigBilateral.glsl'),
    # movie candidates
    'movie_fsrcnnx_only': lambda r: {'shaders': ['FSRCNNX_x2_16-0-4-1.glsl', 'CfL_Prediction.glsl'], 'opts': EWA_D},
    'movie_aiupscale_hq': lambda r: {'shaders': [('AiUpscale_HQ_3x_Photo.glsl' if RATIO[r] > 2.4 else 'AiUpscale_HQ_2x_Photo.glsl'),
                                                 'CfL_Prediction.glsl'], 'opts': EWA_D},
    'movie_aiupscale_hq_sharp': lambda r: {'shaders': [('AiUpscale_HQ_Sharp_3x_Photo.glsl' if RATIO[r] > 2.4 else 'AiUpscale_HQ_Sharp_2x_Photo.glsl'),
                                                       'CfL_Prediction.glsl'], 'opts': EWA_D},
    # anime: Anime4K variants
    'anime_cfl': lambda r: {'shaders': ['CfL_Prediction.glsl'] + ANIME},
    'anime_noadp_ewa': anime4k('Anime4K_Upscale_Denoise_CNN_x2_VL.glsl', 'Anime4K_Restore_CNN_M.glsl',
                               'Anime4K_Upscale_CNN_x2_M.glsl', adp=False, opts=EWA_D),
    'anime_noadp_hermite': anime4k('Anime4K_Upscale_Denoise_CNN_x2_VL.glsl', 'Anime4K_Restore_CNN_M.glsl',
                                   'Anime4K_Upscale_CNN_x2_M.glsl', adp=False),
    'anime_ul_l': anime4k('Anime4K_Upscale_Denoise_CNN_x2_UL.glsl', 'Anime4K_Restore_CNN_L.glsl',
                          'Anime4K_Upscale_CNN_x2_L.glsl'),
    'anime_mode_a_hq': lambda r: {'shaders': ['Anime4K_Clamp_Highlights.glsl', 'Anime4K_Restore_CNN_VL.glsl',
                                              'Anime4K_Upscale_CNN_x2_VL.glsl', 'Anime4K_AutoDownscalePre_x2.glsl',
                                              'Anime4K_AutoDownscalePre_x4.glsl', 'Anime4K_Upscale_CNN_x2_M.glsl']},
    # anime: other networks (2x, mpv scales the rest)
    'anime_cunny4_ds': single('CuNNy-4x32-DS.glsl'),
    'anime_cunny8_ds': single('CuNNy-8x32-DS.glsl'),
    'anime_ani4kv2': single('Ani4Kv2_ArtCNN_C4F32_i2_CMP.glsl'),
    'anime_animejanai_v3': single('AnimeJaNaiV3L1_HD_x2.glsl'),
    'anime_artcnn_c4f32_ds': single('ArtCNN_C4F32_DS.glsl'),
}
