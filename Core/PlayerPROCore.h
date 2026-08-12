/*
 *  PlayerPROCore.h
 *  PPMacho
 *
 *  Created by C.W. Betts on 11/22/09.
 *  Copyright 2009 __MyCompanyName__. All rights reserved.
 *
 */

#ifndef __PLAYERPROCORE_H__
#define __PLAYERPROCORE_H__

#include "MADDefs.h"
#include "MAD.h"
#include "MADFileUtils.h"
#include "RDriver.h"

/// Legacy engine helper used by the original Pattern menu. Long patterns are
/// split and sequence references are updated; short patterns are padded.
void ConvertTo64Rows(MADMusic *music);

#ifdef _MAC_H
//! Project version number for PlayerPROCore.
EXP double PlayerPROCoreVersionNumber;

//! Project version string for PlayerPROCore.
EXP const unsigned char PlayerPROCoreVersionString[];
#endif

#if defined(_MAC_H) && TARGET_OS_OSX
#include "RDriverCarbon.h"
#endif

#endif
