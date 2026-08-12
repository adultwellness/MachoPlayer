//
//  VSTFunctions.h
//  PPMacho
//
//  Created by C.W. Betts on 2/6/14.
//
//

#ifndef PPMacho_VSTFunctions_h
#define PPMacho_VSTFunctions_h

#include "RDriver.h"

#define PP_BUILTIN_FREEVERB_ID ((uint32_t)0x46526576U) /* 'FRev' */
#define PP_BUILTIN_DJ_FILTER_ID ((uint32_t)0x444A466CU) /* 'DJFl' */
#define PP_BUILTIN_COMPRESSOR_ID ((uint32_t)0x436F6D70U) /* 'Comp' */
#define PP_BUILTIN_GLOBAL_EFFECT_SLOTS 10
#define PP_BUILTIN_TRACK_EFFECT_SLOTS 4
#define PP_BUILTIN_EFFECT_PARAMETER_COUNT 8

typedef struct PPBuiltinEffectSlot {
	uint32_t effectID;
	float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT];
} PPBuiltinEffectSlot;

#ifdef __cplusplus
extern "C" {
#endif

void		DisposeVSTEffect(VSTEffect *myEffect);
VSTEffect*	CreateVSTEffect(short effectID);
short		ConvertUniqueIDToIndex(uint32_t);
void		ApplyVSTSets(VSTEffect* myEffect, FXSets* set);
bool		IsVSTChanEffect(MADDriverRec *intDriver, short channel);
void		ProcessVSTPlug(MADDriverRec *intDriver, int *data, int datasize, short channel);

/// PlayerPRO's built-in effect host. These calls intentionally mirror the
/// dormant VST routing without loading third-party code.
void		MADInitializeBuiltinEffects(MADDriverRec *intDriver);
void		MADDisposeBuiltinEffects(MADDriverRec *intDriver);
void		MADConfigureBuiltinFreeverb(MADDriverRec *intDriver, bool globalEnabled,
			const bool *trackEnabled, size_t trackCount);
void		MADConfigureBuiltinEffectChains(MADDriverRec *intDriver, bool globalEnabled,
			const PPBuiltinEffectSlot globalSlots[PP_BUILTIN_GLOBAL_EFFECT_SLOTS],
			const bool *trackEnabled,
			const PPBuiltinEffectSlot (*trackSlots)[PP_BUILTIN_TRACK_EFFECT_SLOTS],
			size_t trackCount);
/// Changes a running built-in effect without replacing it or clearing its DSP state.
bool		MADUpdateBuiltinEffectParameters(MADDriverRec *intDriver, bool global,
			size_t track, size_t slot, uint32_t effectID,
			const float values[PP_BUILTIN_EFFECT_PARAMETER_COUNT]);

#ifdef __cplusplus
}
#endif

#endif
