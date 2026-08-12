/********************						***********************/
//
//	Player PRO 5.0 - DRIVER SOURCE CODE -
//
//	Library Version 5.0
//
//	To use with MAD Library for Mac: Symantec, CodeWarrior and MPW
//
//	Antoine ROSSET
//	16 Tranchees
//	1206 GENEVA
//	SWITZERLAND
//
//	COPYRIGHT ANTOINE ROSSET 1996, 1997, 1998
//
//	Thank you for your interest in PlayerPRO !
//
//	FAX:				(+41 22) 346 11 97
//	PHONE: 			(+41 79) 203 74 62
//	Internet: 	RossetAntoine@bluewin.ch
//
/********************						***********************/

//Needed to quiet a few warnings on Windows.
#define _CRT_SECURE_NO_WARNINGS 1

#if defined(__APPLE__) && !(defined(EMBEDPLUGS) && EMBEDPLUGS)
#include <PlayerPROCore/PlayerPROCore.h>
#else
#include "RDriver.h"
#include "MADFileUtils.h"
#endif

#if defined(EMBEDPLUGS) && EMBEDPLUGS
#include "embeddedPlugs.h"
#endif

#ifndef WIN32
//Windows Defines
typedef int16_t		WORD;
typedef uint16_t	UWORD;
#if !defined(__COREFOUNDATION_CFPLUGINCOM__)
typedef int32_t		HRESULT;
typedef uint32_t	ULONG;
#endif
typedef void*		LPVOID;
typedef int32_t		LONG;

typedef uint16_t	UINT;
#ifndef __OBJC__
typedef bool		BOOL;
#endif
typedef uint32_t	DWORD;
typedef uint16_t	USHORT;
typedef int16_t		SHORT;
typedef MADFourChar	FOURCC;
typedef int8_t		BYTE;
#endif

typedef uint8_t		UBYTE;

#include "XM.h"

#include <limits.h>
#include <math.h>

/**************************************************************************
 **************************************************************************/

#define HEADERSIZE 	276
#define PHSIZE		9
#define IHSIZE		263
#define IHSIZESMALL	33
#define IHSSIZE		40
#define XM_MIN(a, b) ((a) < (b) ? (a) : (b))
#define XM_MAX(a, b) ((a) > (b) ? (a) : (b))

struct staticXMData {
	MADByte		LastAEffect[MAXTRACK];
	XMHEADER	*mh;
	char		*theXMRead, *theXMMax;
};

#define READXMFILE(dst, size) do { \
	if (!XM_ReadBytes((dst), (size), xmData)) return MADIncompatibleFile; \
} while (0)
#define WRITEXMFILE(src, size)	{memcpy(xmData->theXMRead, src, size);	xmData->theXMRead += (long) size;}

static bool XM_ReadBytes(void *destination, size_t size, struct staticXMData *xmData)
{
	if (xmData == NULL || destination == NULL || xmData->theXMRead == NULL ||
		xmData->theXMMax == NULL || xmData->theXMRead > xmData->theXMMax ||
		size > (size_t)(xmData->theXMMax - xmData->theXMRead)) {
		return false;
	}
	memcpy(destination, xmData->theXMRead, size);
	xmData->theXMRead += size;
	return true;
}

static bool XM_RangeAvailable(const char *start, size_t size,
	const struct staticXMData *xmData)
{
	return xmData != NULL && start != NULL && xmData->theXMMax != NULL &&
		start <= xmData->theXMMax &&
		size <= (size_t)(xmData->theXMMax - start);
}

static bool XM_Init(MADDriverSettings *init, struct staticXMData *xmData)
{
	xmData->mh = (XMHEADER*)malloc(sizeof(XMHEADER));
	if (xmData->mh == NULL)
		return false;
	else
		return true;
}


static void XM_Cleanup(struct staticXMData *xmData)
{
	if (xmData->mh != NULL) {
		free(xmData->mh);
		xmData->mh = NULL;
	}
}

#if !defined(NOEXPORTMUSIC) || NOEXPORTMUSIC == 0
static void XM_WriteNote(Cmd *cmd, struct staticXMData *xmData)
{
	UBYTE	cmp = 0;
	int		r;
	
	if (cmd->note)
		cmp |= 1;
	if (cmd->ins)
		cmp |= 2;
	if (cmd->vol)
		cmp |= 4;
	if (cmd->cmd)
		cmp |= 8;
	if (cmd->arg)
		cmp |= 16;
	
	if (cmp == 31)		// all bytes used -> no compression
	{
		WRITEXMFILE(&cmd->note, 1);
		WRITEXMFILE(&cmd->ins, 1);
		WRITEXMFILE(&cmd->vol, 1);
		WRITEXMFILE(&cmd->cmd, 1);
		WRITEXMFILE(&cmd->arg, 1);
	} else {
		UBYTE ccmp = cmp + 0x80;
		
		WRITEXMFILE(&ccmp, 1);
		
		r = cmp & 1;
		if (r) {
			WRITEXMFILE(&cmd->note, 1);
		}
		r = cmp & 2;
		if (r) {
			WRITEXMFILE(&cmd->ins, 1);
		}
		r = cmp & 4;
		if (r) {
			WRITEXMFILE(&cmd->vol, 1);
		}
		r = cmp & 8;
		if (r) {
			WRITEXMFILE(&cmd->cmd, 1);
		}
		r = cmp & 16;
		if (r) {
			WRITEXMFILE(&cmd->arg, 1);
		}
	}
}
#endif

static MADErr XM_ReadNote(XMNOTE *n, struct staticXMData *xmData)
{
	UBYTE	cmp;
	int		r;
	
	READXMFILE(&cmp, 1);
	
	r = cmp & 0x80;
	if (r) {
			r = cmp & 1L;
			if (r) {
				READXMFILE(&n->note, 1);
			} else {
				n->note = 0xFF;
			}
			r = cmp & 2L;
			if (r) {
				READXMFILE(&n->ins, 1);
			} else {
				n->ins = 0;
			}
			r = cmp & 4L;
			if (r) {
				READXMFILE(&n->vol, 1);
			} else {
				n->vol = 0xFF;
			}
			r = cmp & 8L;
			if (r) {
				READXMFILE(&n->eff, 1);
			} else {
				n->eff = 0xFF;
			}
			r = cmp & 16L;
			if (r) {
				READXMFILE(&n->dat, 1);
			} else {
				n->dat = 0xFF;
			}
	} else {
		n->note	=	cmp;
		READXMFILE(&n->ins, 1);
		READXMFILE(&n->vol, 1);
		READXMFILE(&n->eff, 1);
		READXMFILE(&n->dat, 1);
	}
	return MADNoErr;
}

static void XM_Convert2MAD(XMNOTE *xmtrack, Cmd *aCmd, UWORD instrumentCount)
{
	UBYTE note,ins,vol,eff,dat;
	
	note = xmtrack->note;
	if (note == 0 || note == 0xFF || note > 97)
		note = 0xFF;
	else
		note--;
	
	ins		=	xmtrack->ins;
	vol		=	xmtrack->vol;
	eff		=	xmtrack->eff;
	dat		=	xmtrack->dat;
	if (ins > instrumentCount)
		ins = 0;
	if (vol == 0 || vol == 0xFF || vol < 0x10 ||
		(vol > 0x50 && vol < 0x60))
		vol = 0xFF;
	
	aCmd->ins		= ins;
	aCmd->note		= note;
	aCmd->vol		= vol;
	if (note == 96) {						// KEY OFF
		aCmd->note		= 0xFE;
	}
	
	
	//	if (eff == 0 && dat != 0) Debugger();
	
	if (eff <= 0x0F) {
		aCmd->cmd		= eff;
		aCmd->arg		= dat;
		
		if (aCmd->arg == 0xFF) {
			switch(aCmd->cmd)
			{
				case MADEffectPortamento:
					break;
					
				default:
					aCmd->arg = 0;
					break;
			}
		}
		
		if (aCmd->cmd == MADEffectSlideVolume) {
#if 0
			if (aCmd->arg == 0)
				aCmd->arg = LastAEffect[channel];
			else
				LastAEffect[channel] = aCmd->arg;
#endif
		}
	} else {
		aCmd->cmd		= 0;
		aCmd->arg		= dat;
		if (aCmd->arg == 0xFF)
			aCmd->arg = 0;
		
		switch(eff) {
			case 255:
				aCmd->cmd		= 0;
				break;
				
			case 'G'-55:					// G - set global volume
				aCmd->arg = 0;
				break;
				
			case 'H'-55:					// H - global volume slide
				aCmd->arg = 0;
				break;
				
			case 'K'-55:					// K - keyoff
				aCmd->ins		= 00;
				aCmd->note		= 0xFE;
				break;
				
			case 'L'-55:					// L - set envelope position
				aCmd->arg = 0;
				break;
				
			case 'P'-55:					// P - panning slide
				//	Convert en slide panning (volume cmd !)
				aCmd->cmd		= 0;
				aCmd->arg		= 0;
				
			{
				MADByte	lo, hi;
				
				lo = dat & 0xf;
				hi = dat >> 4;
				
				/* slide right has absolute priority */
				if (hi)
					lo = 0;
				
				if (hi)
					aCmd->vol = 0xE0 + hi;
				else
					aCmd->vol = 0xD0 + lo;
			}
				break;
				
			case 'R'-55:					// R - multi retrig note
				if ((dat & 0x0F) != 0) {
					aCmd->cmd = MADEffectExtended;
					aCmd->arg = 0x90 | (dat & 0x0F);
				} else {
					aCmd->arg = 0;
				}
				break;
				
			case 'T'-55:
				aCmd->arg = 0;
				break;
				
			case 'X'-55:
				if ((dat >> 4) == 1) {	// X1 extra fine porta up
					aCmd->cmd = MADEffectExtended;
					aCmd->arg = 0x10 | (dat & 0x0F);
				} else if ((dat >> 4) == 2) { // X2 extra fine porta down
					aCmd->cmd = MADEffectExtended;
					aCmd->arg = 0x20 | (dat & 0x0F);
				} else {
					aCmd->arg = 0;
				}
				break;
				
			default:
				/*	NumToString(eff, str);
				 DebugStr(str);*/
				aCmd->arg = 0;
				break;
		}
	}
}

#if !defined(NOEXPORTMUSIC) || NOEXPORTMUSIC == 0
static void XM_Convert2XM(Cmd *aCmd)
{
	if (aCmd->note == 0xFE)
		aCmd->note = 96 + 1;	// KEY OFF
	else if (aCmd->note == 0xFF)
		aCmd->note = 0;
	else
		aCmd->note++;
	
	if (aCmd->vol == 0xFF)
		aCmd->vol = 0;
	if ((MADByte)aCmd->cmd == 0xFF)
		aCmd->cmd = 0;
}
#endif

static MADErr XMReadPattern(MADMusic *theMAD, MADDriverSettings *init, struct staticXMData *xmData)
{
	int t, u, v, i;
	
	/*****************/
	/** PATTERNS **/
	/*****************/
	
	for (i = 0; i < MAXPATTERN; i++)
		theMAD->partition[i] = NULL;
	for (i = 0; i < MAXTRACK; i++)
		xmData->LastAEffect[i] = 0;
	
	for (t = 0; t < xmData->mh->numpat; t++) {
		short		PatternSize;
		XMPATHEADER	ph;
		XMNOTE		xmpat;
		Cmd			*aCmd;
		char		*theXMReadCopy;
		
		theXMReadCopy = xmData->theXMRead;
		if (!XM_RangeAvailable(theXMReadCopy, PHSIZE, xmData))
			return MADIncompatibleFile;
		READXMFILE(&ph.size, 		4);
		MADLE32(&ph.size);
		READXMFILE(&ph.packing, 	1);
		READXMFILE(&ph.numrows, 	2);
		MADLE16(&ph.numrows);
		READXMFILE(&ph.packsize, 	2);
		MADLE16(&ph.packsize);
		if (ph.size < PHSIZE || !XM_RangeAvailable(theXMReadCopy, ph.size, xmData))
			return MADIncompatibleFile;
		xmData->theXMRead = theXMReadCopy + ph.size;
		if (ph.numrows == 0 || ph.numrows > MAXPATTERNSIZE ||
			!XM_RangeAvailable(xmData->theXMRead, ph.packsize, xmData))
			return MADIncompatibleFile;
		char *patternDataEnd = xmData->theXMRead + ph.packsize;
		
		/*
		 Gr8.. when packsize is 0, don't try to load a pattern.. it's empty.
		 This bug was discovered thanks to Khyron's module..
		 */

		PatternSize = ph.numrows;
		size_t commandCount = (size_t)theMAD->header->numChn * (size_t)PatternSize;
		if (commandCount > (SIZE_MAX - sizeof(PatHeader)) / sizeof(Cmd))
			return MADIncompatibleFile;
		theMAD->partition[t] = (PatData*)calloc(
			sizeof(PatHeader) + commandCount * sizeof(Cmd), 1);
		if (theMAD->partition[t] == NULL)
			return MADNeedMemory;
		theMAD->partition[t]->header.size = PatternSize;
		theMAD->partition[t]->header.compMode = 'NONE';

		if (ph.packsize > 0) {
			char *fileEnd = xmData->theXMMax;
			xmData->theXMMax = patternDataEnd;
			MADErr readError = MADNoErr;
			for (u = 0 ; u < PatternSize ; u++) {
				for (v = 0 ; v < theMAD->header->numChn ; v++) {
					readError = XM_ReadNote(&xmpat, xmData);
					if (readError != MADNoErr)
						break;
					
					aCmd = GetMADCommand(u, v, theMAD->partition[t]);
					
					XM_Convert2MAD(&xmpat, aCmd, xmData->mh->numins);
				}
				if (readError != MADNoErr)
					break;
			}
			xmData->theXMMax = fileEnd;
			if (readError != MADNoErr)
				return readError;
		} else {
			Cmd			nullCmd;
			
			nullCmd.ins		= 0;
			nullCmd.note	= 0xFF;
			nullCmd.cmd		= 0;
			nullCmd.arg		= 0;
			nullCmd.vol		= 0xFF;
			nullCmd.unused	= 0;
			
			for (u = 0 ; u < PatternSize ; u++) {
				for (v = 0 ; v < theMAD->header->numChn ; v++) {
					aCmd = GetMADCommand(u, v, theMAD->partition[t]);
					*aCmd = nullCmd;
				}
			}
		}
		xmData->theXMRead = patternDataEnd;
	}
	
	return MADNoErr;
}

static void XM_NormalizeEnvelope(EnvRec *envelope, MADByte *pointCount,
	MADByte *sustain, MADByte *loopStart, MADByte *loopEnd, EFType *type)
{
	*pointCount = XM_MIN(*pointCount, 12);
	if (*pointCount == 0) {
		*sustain = *loopStart = *loopEnd = 0;
		*type = 0;
		return;
	}
	short previousPosition = 0;
	for (int point = 0; point < *pointCount; point++) {
		uint16_t sourcePosition = (uint16_t)envelope[point].pos;
		envelope[point].pos = (short)XM_MIN(sourcePosition, SHRT_MAX);
		if (envelope[point].pos < previousPosition)
			envelope[point].pos = previousPosition;
		previousPosition = envelope[point].pos;
		envelope[point].val = XM_MIN(XM_MAX(envelope[point].val, 0), 64);
	}
	*sustain = XM_MIN(*sustain, *pointCount - 1);
	*loopStart = XM_MIN(*loopStart, *pointCount - 1);
	*loopEnd = XM_MIN(*loopEnd, *pointCount - 1);
	if (*loopStart > *loopEnd)
		*loopStart = *loopEnd;
	*type &= (EFTypeOn | EFTypeSustain | EFTypeLoop);
}

static MADErr XMReadInstruments(MADMusic *theMAD, MADDriverSettings *init,
	struct staticXMData *xmData)
{
	(void)init;
	int totalSamples = 0;
	theMAD->fid = (InstrData*)calloc(MAXINSTRU, sizeof(InstrData));
	if (theMAD->fid == NULL)
		return MADNeedMemory;
	theMAD->sample = (sData**)calloc((size_t)MAXINSTRU * MAXSAMPLE, sizeof(sData*));
	if (theMAD->sample == NULL)
		return MADNeedMemory;
	for (int instrument = 0; instrument < MAXINSTRU; instrument++)
		theMAD->fid[instrument].firstSample = instrument * MAXSAMPLE;

	for (int instrument = 0; instrument < xmData->mh->numins; instrument++) {
		XMINSTHEADER ih = {0};
		InstrData *curIns = &theMAD->fid[instrument];
		char *instrumentHeader = xmData->theXMRead;
		if (!XM_RangeAvailable(instrumentHeader, 29, xmData))
			return MADIncompatibleFile;
		READXMFILE(&ih.size, 4);
		MADLE32(&ih.size);
		READXMFILE(ih.name, 22);
		READXMFILE(&ih.type, 1);
		READXMFILE(&ih.numsmp, 2);
		MADLE16(&ih.numsmp);
		if (ih.size < 29 || !XM_RangeAvailable(instrumentHeader, ih.size, xmData) ||
			ih.numsmp > MAXSAMPLE)
			return MADIncompatibleFile;
		char *instrumentHeaderEnd = instrumentHeader + ih.size;

		memcpy(curIns->name, ih.name, 22);
		curIns->type = ih.type;
		curIns->no = (MADByte)instrument;
		curIns->numSamples = (short)ih.numsmp;

		if (ih.numsmp > 0) {
			if (ih.size < IHSIZE)
				return MADIncompatibleFile;
			XMPATCHHEADER pth = {0};
			READXMFILE(&ih.ssize, 4);
			MADLE32(&ih.ssize);
			if (ih.ssize < IHSSIZE)
				return MADIncompatibleFile;
			READXMFILE(pth.what, 96);
			READXMFILE(pth.volenv, 48);
			READXMFILE(pth.panenv, 48);
			READXMFILE(&pth.volpts, 1);
			READXMFILE(&pth.panpts, 1);
			READXMFILE(&pth.volsus, 1);
			READXMFILE(&pth.volbeg, 1);
			READXMFILE(&pth.volend, 1);
			READXMFILE(&pth.pansus, 1);
			READXMFILE(&pth.panbeg, 1);
			READXMFILE(&pth.panend, 1);
			READXMFILE(&pth.volflg, 1);
			READXMFILE(&pth.panflg, 1);
			READXMFILE(&pth.vibflg, 1);
			READXMFILE(&pth.vibsweep, 1);
			READXMFILE(&pth.vibdepth, 1);
			READXMFILE(&pth.vibrate, 1);
			READXMFILE(&pth.volfade, 2);
			MADLE16(&pth.volfade);
			READXMFILE(pth.reserved, 22);

			for (int note = 0; note < 96; note++)
				curIns->what[note] = pth.what[note] < ih.numsmp ? pth.what[note] : 0;
			memcpy(curIns->volEnv, pth.volenv, sizeof(curIns->volEnv));
			memcpy(curIns->pannEnv, pth.panenv, sizeof(curIns->pannEnv));
			for (int point = 0; point < 12; point++) {
				MADLE16(&curIns->volEnv[point].pos);
				MADLE16(&curIns->volEnv[point].val);
				MADLE16(&curIns->pannEnv[point].pos);
				MADLE16(&curIns->pannEnv[point].val);
			}
			curIns->volSize = pth.volpts;
			curIns->volSus = pth.volsus;
			curIns->volBeg = pth.volbeg;
			curIns->volEnd = pth.volend;
			curIns->volType = pth.volflg;
			XM_NormalizeEnvelope(curIns->volEnv, &curIns->volSize,
				&curIns->volSus, &curIns->volBeg, &curIns->volEnd, &curIns->volType);
			curIns->pannSize = pth.panpts;
			curIns->pannSus = pth.pansus;
			curIns->pannBeg = pth.panbeg;
			curIns->pannEnd = pth.panend;
			curIns->pannType = pth.panflg;
			XM_NormalizeEnvelope(curIns->pannEnv, &curIns->pannSize,
				&curIns->pannSus, &curIns->pannBeg, &curIns->pannEnd, &curIns->pannType);
			curIns->volFade = pth.volfade;
			curIns->vibDepth = pth.vibdepth;
			curIns->vibRate = pth.vibrate;
		}
		xmData->theXMRead = instrumentHeaderEnd;

		for (int sample = 0; sample < ih.numsmp; sample++) {
			XMWAVHEADER wh = {0};
			char *sampleHeader = xmData->theXMRead;
			if (!XM_RangeAvailable(sampleHeader, ih.ssize, xmData))
				return MADIncompatibleFile;
			READXMFILE(&wh.length, 4);
			MADLE32(&wh.length);
			READXMFILE(&wh.loopstart, 4);
			MADLE32(&wh.loopstart);
			READXMFILE(&wh.looplength, 4);
			MADLE32(&wh.looplength);
			READXMFILE(&wh.volume, 1);
			READXMFILE(&wh.finetune, 1);
			READXMFILE(&wh.type, 1);
			READXMFILE(&wh.panning, 1);
			READXMFILE(&wh.realNote, 1);
			READXMFILE(&wh.reserved, 1);
			READXMFILE(wh.samplename, 22);
			xmData->theXMRead = sampleHeader + ih.ssize;
			if (wh.length > INT_MAX || wh.loopstart > wh.length ||
				wh.looplength > wh.length - wh.loopstart)
				return MADIncompatibleFile;
			if ((wh.type & 0x10) && ((wh.length | wh.loopstart | wh.looplength) & 1))
				return MADIncompatibleFile;

			sData *curData = (sData*)calloc(1, sizeof(sData));
			if (curData == NULL)
				return MADNeedMemory;
			theMAD->sample[instrument * MAXSAMPLE + sample] = curData;
			curData->size = (int)wh.length;
			curData->loopBeg = (int)wh.loopstart;
			curData->loopSize = (int)wh.looplength;
			curData->vol = XM_MIN(wh.volume, MAX_VOLUME);
			double fineSemitones = (double)(int8_t)wh.finetune / 128.0;
			curData->c2spd = (unsigned short)XM_MIN(XM_MAX(
				lrint(8363.0 * pow(2.0, fineSemitones / 12.0)), 1), USHRT_MAX);
			curData->amp = (wh.type & 0x10) ? 16 : 8;
			curData->loopType = (wh.type & 0x03) == 2 ?
				MADLoopTypePingPong : MADLoopTypeClassic;
			if ((wh.type & 0x03) == 0 || (wh.type & 0x03) == 3 ||
				curData->loopSize <= 2) {
				curData->loopBeg = 0;
				curData->loopSize = 0;
				curData->loopType = MADLoopTypeClassic;
			}
			curData->realNote = wh.realNote;
			memcpy(curData->name, wh.samplename, 22);
			totalSamples++;
		}

		for (int sample = 0; sample < curIns->numSamples; sample++) {
			sData *curData = theMAD->sample[instrument * MAXSAMPLE + sample];
			if (curData->size == 0)
				continue;
			curData->data = (char*)malloc((size_t)curData->size);
			if (curData->data == NULL)
				return MADNeedMemory;
			READXMFILE(curData->data, (size_t)curData->size);
			if (curData->amp == 16) {
				int16_t accumulator = 0;
				for (int index = 0; index < curData->size / 2; index++) {
					int16_t delta = 0;
					memcpy(&delta, curData->data + index * 2, sizeof(delta));
					MADLE16(&delta);
					accumulator = (int16_t)((int32_t)accumulator + delta);
					memcpy(curData->data + index * 2, &accumulator, sizeof(accumulator));
				}
			} else {
				int8_t accumulator = 0;
				for (int index = 0; index < curData->size; index++) {
					int8_t delta = (int8_t)curData->data[index];
					accumulator = (int8_t)((int)accumulator + delta);
					curData->data[index] = (char)accumulator;
				}
			}
		}
	}
	theMAD->header->numInstru = (MADByte)xmData->mh->numins;
	theMAD->header->numSamples = (MADByte)XM_MIN(totalSamples, UINT8_MAX);
	return MADNoErr;
}

static MADErr XM_Load(char* theXM, size_t XMSize, MADMusic *theMAD, MADDriverSettings *init, struct staticXMData *xmData)
{
	int		i;
	int		inOutCount;
	MADErr	iErr = MADNoErr;
	
	if (theXM == NULL || theMAD == NULL || XMSize < sizeof(XMHEADER))
		return MADIncompatibleFile;
	xmData->theXMRead = theXM;
	xmData->theXMMax = theXM + XMSize;
	
	/********************/
	/** READ XM HEADER **/
	/********************/
	
	READXMFILE(xmData->mh, sizeof(XMHEADER));
	/* BigEndian <-> LittleEndian */
	
	MADLE16(&xmData->mh->version);
	MADLE32(&xmData->mh->headersize);
	MADLE16(&xmData->mh->songlength);
	MADLE16(&xmData->mh->restart);
	MADLE16(&xmData->mh->numchn);
	MADLE16(&xmData->mh->numpat);
	MADLE16(&xmData->mh->numins);
	
	MADLE16(&xmData->mh->flags);
	MADLE16(&xmData->mh->bpm);
	MADLE16(&xmData->mh->tempo);
	if (memcmp(xmData->mh->id, "Extended Module: ", 17) != 0 ||
		xmData->mh->songname[20] != 0x1A ||
		xmData->mh->version != 0x0104 ||
		xmData->mh->headersize < HEADERSIZE ||
		xmData->mh->headersize > XMSize - 60 ||
		xmData->mh->songlength == 0 || xmData->mh->songlength > UINT8_MAX ||
		xmData->mh->numchn == 0 || xmData->mh->numchn > UINT8_MAX ||
		xmData->mh->numpat == 0 || xmData->mh->numpat > MAXPATTERN ||
		xmData->mh->numins > MAXINSTRU ||
		xmData->mh->tempo == 0 || xmData->mh->tempo > 31 ||
		xmData->mh->bpm < 32 || xmData->mh->bpm > 255)
		return MADIncompatibleFile;
	xmData->theXMRead = theXM + 60 + xmData->mh->headersize;
	
	/********************/
	/** MAD ALLOCATION **/
	/********************/
	
	inOutCount = sizeof(MADSpec);
	theMAD->header = (MADSpec*)calloc(inOutCount, 1);
	if (theMAD->header == NULL)
		return MADNeedMemory;
	
	theMAD->header->MAD = 'MADK';
	
	for (i = 0; i < 20; i++) {
		if (xmData->mh->songname[i] == 0x1a) {
			theMAD->header->name[i] = 0;
			break;
		}
		theMAD->header->name[i] = xmData->mh->songname[i];
		if (theMAD->header->name[i] == 0)
			break;
	}
	
	theMAD->header->speed		= 	xmData->mh->tempo;
	theMAD->header->tempo		=	xmData->mh->bpm;
	theMAD->header->numChn		=	xmData->mh->numchn;
	theMAD->header->numPat		=	xmData->mh->numpat;
	theMAD->header->numPointers	=	xmData->mh->songlength;
	
	strncpy(theMAD->header->infos, "Converted by PlayerPRO XM Plug (\251Antoine ROSSET <rossetantoine@bluewin.ch>)", sizeof(theMAD->header->infos));
	
	for (i = 0; i < theMAD->header->numPointers; i++) {
		theMAD->header->oPointers[i] = xmData->mh->orders[i];
		if (theMAD->header->oPointers[i] >= theMAD->header->numPat)
			return MADIncompatibleFile;
	}
	
	if (xmData->mh->flags & 1)
		theMAD->header->XMLinear = true;
	
	for (i = 0; i < MAXTRACK; i++) {
		/*	if (x > 0) theMAD->header->chanPan[i] = MAX_PANNING/4;
		 else theMAD->header->chanPan[i] = MAX_PANNING - MAX_PANNING/4;
		 x--;
		 
		 if (x == -2) x = 2;*/
		
		theMAD->header->chanVol[i] = MAX_VOLUME;
		theMAD->header->chanPan[i] = MAX_PANNING / 2;
	}
	
	theMAD->header->generalVol		= 64;
	theMAD->header->generalSpeed	= 80;
	theMAD->header->generalPitch	= 80;
	
	theMAD->sets = (FXSets*)calloc(MAXTRACK, sizeof(FXSets));
	if (theMAD->sets == NULL)
		return MADNeedMemory;
	for (i = 0; i < MAXTRACK; i++)
		theMAD->header->chanBus[i].copyId = i;
	
	switch (xmData->mh->version) {
		case 0x104:
			iErr = XMReadPattern(theMAD, init, xmData);
			if (iErr == MADNoErr)
				iErr = XMReadInstruments(theMAD, init, xmData);
			break;
			
			/*	case 0x103:
			 XMReadInstruments(theMAD);
			 XMReadPattern(theMAD);
			 break;*/
			
		default:
			return MADFileNotSupportedByThisPlug;
			break;
	}
	
	return iErr;
}

//This Function isn't used right now. #if 0'ing out
#if 0
static int ConvertSampleC4SPDXM(char* src, size_t srcSize, short amp, int srcC4SPD, char* dst, int dstC4SPD)
{
	short	*src16 = (short*) src, *dst16 = (short*) dst;
	char*		src8 = src, dst8 = dst;
	int		x;
	
	if (amp == 8)
	{
		for(x = 0; x < srcSize; x++)
		{
			dst8[(x * dstC4SPD) / srcC4SPD] = src8[x];
		}
	}
	else
	{
		for(x = 0; x < srcSize/2; x++)
		{
			dst16[(x * dstC4SPD) / srcC4SPD] = src16[x];
		}
	}
	
	return (srcSize * dstC4SPD) / srcC4SPD;
}
#endif

#if !defined(NOEXPORTMUSIC) || NOEXPORTMUSIC == 0
static long XMGetPeriod(short note, int c2spd)
{
	uint32_t 	period, n,o, mytab[12] = {1712 * 16, 1616 * 16, 1524 * 16, 1440 * 16, 1356 * 16, 1280 * 16,
		1208 * 16, 1140 * 16, 1076 * 16, 1016 * 16, 960 * 16, 907 * 16 };
	
	n = note % 12;
	o = note / 12;
	
	period = ((8363U * (mytab[n])) >> o ) / c2spd;
	
	if (period == 0)
		period = 7242;
	
	return period;
}

static char* ConvertMad2XM(MADMusic *theMAD, MADDriverSettings *init, long *sndSize, struct staticXMData *xmData)
{
	int		u, i;
	size_t	PatternSize, InstruSize;
	int		NumberInstru;
	char*		finalXMPtr;
	
	/********************************/
	/* 			MAD INFORMATIONS    */
	/********************************/
	InstruSize 		= 0;
	PatternSize 	= 0;
	
	NumberInstru = MAXINSTRU;
	
	for (i = 0; i < MAXINSTRU ; i++) {
		InstruSize += sizeof(XMINSTHEADER) + sizeof(XMPATCHHEADER);
		
		for (u = 0; u < theMAD->fid[i].numSamples; u++) {
			InstruSize += sizeof(XMWAVHEADER) + theMAD->sample[i*MAXSAMPLE + u]->size;
		}
		
		if (theMAD->fid[i].numSamples > 0 || theMAD->fid[i].name[0] != 0) {
			NumberInstru = i + 1;
		}
	}
	
	for (i = 0; i < theMAD->header->numPat;i++) {
		PatternSize += sizeof(XMNOTE) * theMAD->header->numChn * theMAD->partition[i]->header.size;
		PatternSize += sizeof(XMPATHEADER);
	}
	/********************************/
	
	*sndSize = sizeof(XMHEADER) + InstruSize + PatternSize;
	
	xmData->theXMRead = finalXMPtr = (char*)malloc(*sndSize);
	xmData->theXMMax = xmData->theXMRead + *sndSize;
	if (xmData->theXMRead == NULL)
		return NULL;
	
	/********************/
	/** WRITE XM HEADER */
	/********************/
	
	memcpy(xmData->mh->id, "Extended Module: ", sizeof(xmData->mh->id));
	memcpy(xmData->mh->trackername, "FastTracker v2.00   ", sizeof(xmData->mh->trackername));
	xmData->mh->version			= 0x104;
	MADLE16(&xmData->mh->version);
	xmData->mh->headersize		= HEADERSIZE;
	MADLE32(&xmData->mh->headersize);
	xmData->mh->songlength 		= theMAD->header->numPointers;
	MADLE16(&xmData->mh->songlength);
	xmData->mh->restart 		= 0;
	MADLE16(&xmData->mh->restart);
	xmData->mh->numchn 			= theMAD->header->numChn;
	MADLE16(&xmData->mh->numchn);
	xmData->mh->numpat 			= theMAD->header->numPat;
	MADLE16(&xmData->mh->numpat);
	xmData->mh->numins 			= NumberInstru;
	MADLE16(&xmData->mh->numins);
	xmData->mh->flags 			= 0;
	if (theMAD->header->XMLinear)
		xmData->mh->flags = 1;
	else
		xmData->mh->flags = 0;
	MADLE16(&xmData->mh->flags);
	xmData->mh->bpm 			= theMAD->header->tempo;
	MADLE16(&xmData->mh->bpm);
	xmData->mh->tempo 			= theMAD->header->speed;
	MADLE16(&xmData->mh->tempo);
	
	memset(xmData->mh->songname, ' ', sizeof(xmData->mh->songname));
	for (i = 0; i < 21; i++) {
		xmData->mh->songname[i] = theMAD->header->name[i];
		if (theMAD->header->name[i] == 0)
			i = 21;
	}
	xmData->mh->songname[20] = 0x1a;
	
	memset(xmData->mh->orders, 0, sizeof(xmData->mh->orders));
	for(i = 0; i < theMAD->header->numPointers; i++) xmData->mh->orders[i] = theMAD->header->oPointers[i];
	
	WRITEXMFILE(xmData->mh, sizeof(XMHEADER));
	
	/*****************/
	/** PATTERNS    **/
	/*****************/
	
	{
		int t, u, v;
		
		for (t = 0; t < theMAD->header->numPat; t++) {
			short		PatternSize;
			XMPATHEADER	ph;
			char		*packingCopy, *cc;
			
			ph.size = PHSIZE;
			MADLE32(&ph.size);
			WRITEXMFILE(&ph.size, 4);
			ph.packing = 0;
			WRITEXMFILE(&ph.packing, 1);
			ph.numrows = theMAD->partition[t]->header.size;
			MADLE16(&ph.numrows);
			WRITEXMFILE(&ph.numrows, 2);
			
			packingCopy = xmData->theXMRead;
			ph.packsize = 1;
			MADLE16(&ph.packsize);
			WRITEXMFILE(&ph.packsize, 2);
			
			cc = xmData->theXMRead;
			for (u = 0 ; u < theMAD->partition[t]->header.size ; u++) {
				for (v = 0 ; v < theMAD->header->numChn ; v++) {
					Cmd		*aCmd;
					Cmd		bCmd;
					
					aCmd = GetMADCommand(u, v, theMAD->partition[t]);
					
					bCmd = *aCmd;
					
					XM_Convert2XM(&bCmd);
					
					XM_WriteNote(&bCmd, xmData);
				}
			}
			
			PatternSize = xmData->theXMRead - cc;
			
			cc = xmData->theXMRead;
			xmData->theXMRead = packingCopy;
			ph.packsize = PatternSize;
			MADLE16(&ph.packsize);
			WRITEXMFILE(&ph.packsize, 2);
			xmData->theXMRead = cc;
		}
	}
	
	/*****************/
	/** INSTRUMENTS **/
	/*****************/
	
	{
		int t, u, x;
		
		for (t = 0; t < NumberInstru; t++) {
			XMINSTHEADER 	ih;
			size_t			ihsizecopy, ihssizecopy;
			InstrData		*curIns = &theMAD->fid[t];
			char			*theXMReadCopy = xmData->theXMRead;
			
			//************************//
			// Instrument header size //
			
			if (curIns->numSamples > 0)
				ih.size = IHSIZE;
			else
				ih.size = IHSIZESMALL;
			
			ihsizecopy = ih.size;
			MADLE32(&ih.size);
			WRITEXMFILE(&ih.size, 4);
			
			//************************//
			
			for (x = 0; x < 22; x++)
				ih.name[x] = curIns->name[x];
			WRITEXMFILE(&ih.name, 22);
			ih.type = 0;
			WRITEXMFILE(&ih.type, 1);
			ih.numsmp = curIns->numSamples;
			MADLE16(&ih.numsmp);
			WRITEXMFILE(&ih.numsmp, 2);
			
			ih.ssize = IHSSIZE;
			ihssizecopy = ih.ssize;
			MADLE32(&ih.ssize);
			
			if (curIns->numSamples > 0) {
				XMPATCHHEADER	pth;
				
				memset(&pth, 0, sizeof(pth));
				
				memcpy(pth.what, curIns->what, 96);
				
				memcpy(pth.volenv, curIns->volEnv, 48);
				for (x = 0; x < 24; x++) MADLE16(&pth.volenv[x]);
				
				pth.volpts = curIns->volSize;
				pth.volflg = curIns->volType;
				pth.volsus = curIns->volSus;
				pth.volbeg = curIns->volBeg;
				pth.volend = curIns->volEnd;
				pth.volfade = curIns->volFade;
				
				
				
				memcpy(pth.panenv, curIns->pannEnv, 48);
				for (x = 0; x < 24; x++) MADLE16(&pth.panenv[x]);
				
				pth.panpts = curIns->pannSize;
				pth.panflg = curIns->pannType;
				pth.pansus = curIns->pannSus;
				pth.panbeg = curIns->pannBeg;
				pth.panend = curIns->pannEnd;
				
				
				
				WRITEXMFILE(&ih.ssize,		4);
				WRITEXMFILE(&pth.what,		96);
				WRITEXMFILE(&pth.volenv,	48);
				WRITEXMFILE(&pth.panenv,	48);
				WRITEXMFILE(&pth.volpts,	1);
				WRITEXMFILE(&pth.panpts,	1);
				WRITEXMFILE(&pth.volsus,	1);
				WRITEXMFILE(&pth.volbeg,	1);
				WRITEXMFILE(&pth.volend,	1);
				WRITEXMFILE(&pth.pansus,	1);
				WRITEXMFILE(&pth.panbeg,	1);
				WRITEXMFILE(&pth.panend,	1);
				WRITEXMFILE(&pth.volflg,	1);
				WRITEXMFILE(&pth.panflg,	1);
				WRITEXMFILE(&pth.vibflg,	1);
				WRITEXMFILE(&pth.vibsweep,	1);
				WRITEXMFILE(&pth.vibdepth,	1);
				WRITEXMFILE(&pth.vibrate,	1);
				MADLE16(&pth.volfade);
				WRITEXMFILE(&pth.volfade,	2);
				WRITEXMFILE(&pth.reserved,	22);
			}
			xmData->theXMRead = theXMReadCopy + ihsizecopy;
			
			/** WRITE samples */
			
			for (u = 0 ; u < curIns->numSamples ; u++) {
				XMWAVHEADER	wh;
				sData		*curData;
				short		modifc2spd = 0;
				int			copyc2spd;
				int			finetune[16] = {
					7895,	7941,	7985,	8046,	8107,	8169,	8232,	8280,
					8363,	8413,	8463,	8529,	8581,	8651,	8723,	8757
				};
				
				curData = theMAD->sample[t*MAXSAMPLE + u];
				
				wh.volume = curData->vol;
				
				copyc2spd = curData->c2spd;
				
				if (curData->c2spd > 8757 || curData->c2spd < 7895) {
#define BASECALC 45
					
					wh.finetune = 0;			// <- 8363 Hz
					
					while (XMGetPeriod(BASECALC, curData->c2spd) < XMGetPeriod(BASECALC + modifc2spd, 8363)) {
						modifc2spd++;
					}
					
					curData->c2spd = 8363;
					
					wh.length 		= curData->size;
					wh.loopstart	= curData->loopBeg;
					wh.looplength	= curData->loopSize;
					
					if (curData->stereo) {
						wh.length /= 2;
						wh.loopstart /= 2;
						wh.looplength /= 2;
					}
					
					wh.finetune = -128;
					if (curData->c2spd > 8757)
						wh.finetune = 127;
					else {
						while (finetune[(wh.finetune + 128)/16] < curData->c2spd) {
							wh.finetune += 16;
						}
					}
				}
				
				curData->c2spd = copyc2spd;
				
				wh.type = 0;
				if (curData->amp == 16)
					wh.type |= 0x10;
				if (curData->loopSize > 0) {
					if (curData->loopType == MADLoopTypePingPong)
						wh.type |= 0x2;
					else
						wh.type |= 0x1;
				}
				
				wh.panning = 128;	//curData->panning;
				wh.realNote = curData->realNote + modifc2spd;
				strncpy(wh.samplename, curData->name, sizeof(wh.samplename));
				
				theXMReadCopy = xmData->theXMRead;
				MADLE32(&wh.length);
				WRITEXMFILE(&wh.length,		4);
				MADLE32(&wh.loopstart);
				WRITEXMFILE(&wh.loopstart,	4);
				MADLE32(&wh.looplength);
				WRITEXMFILE(&wh.looplength,	4);
				WRITEXMFILE(&wh.volume,		1);
				WRITEXMFILE(&wh.finetune,	1);
				WRITEXMFILE(&wh.type,		1);
				wh.panning		= 128;
				WRITEXMFILE(&wh.panning,	1);
				WRITEXMFILE(&wh.realNote,	1);
				WRITEXMFILE(&wh.reserved,	1);
				WRITEXMFILE(&wh.samplename,	22);
				xmData->theXMRead = theXMReadCopy + ihssizecopy;
			}
			
			/** WRITE samples data **/
			
			for (u = 0 ; u < curIns->numSamples ; u++) {
				sData	*curData = theMAD->sample[t * MAXSAMPLE + u];
				char	*theXMReadCopy = xmData->theXMRead;
				int		curSize;
				
				WRITEXMFILE(curData->data, curData->size);
				curSize = curData->size;
				
				if (curData->stereo) {
					if (curData->amp == 8) {
						for (x = 0 ; x < curSize; x += 2) {
							theXMReadCopy[x / 2] = ((int)theXMReadCopy[x] + (int) theXMReadCopy[x + 1]) / 2L;
						}
					} else {
						short *short16out = (short*)theXMReadCopy, *short16in = (short*)theXMReadCopy;
						
						for (x = 0 ; x < curSize/2; x += 2) {
							short16out[x / 2] = ((int)short16in[x] + (int)short16in[x + 1]) / 2;
						}
					}
					
					curSize /= 2;
					xmData->theXMRead -= curSize;
				}
				
				if (curData->amp == 16) {
					short	*tt = (short*) theXMReadCopy;
					int		tL;
					
					/* Real to Delta */
					int	oldV = 0, newV;
					int	xL;
					
					for (xL = 0; xL < curSize / 2; xL++) {
						newV = tt[xL];
						tt[xL] -= oldV;
						oldV = newV;
					}
					
					for (tL = 0; tL < curSize / 2; tL++) {
						MADLE16((char*)(tt + tL));
					}
				} else {
					/* Real to Delta */
					int	oldV = 0, newV;
					int	xL;
					
					for (xL = 0; xL < curSize; xL++) {
						newV = theXMReadCopy[xL];
						theXMReadCopy[xL] -= oldV;
						oldV = newV;
					}
				}
			}
		}
	}
	
	*sndSize = xmData->theXMRead - finalXMPtr;
	
	return finalXMPtr;
}
#endif

typedef struct XMFixtureWriter {
	uint8_t bytes[1024];
	size_t length;
} XMFixtureWriter;

static bool XMFixtureBytes(XMFixtureWriter *writer, const void *bytes, size_t length)
{
	if (writer->length > sizeof(writer->bytes) ||
		length > sizeof(writer->bytes) - writer->length)
		return false;
	memcpy(writer->bytes + writer->length, bytes, length);
	writer->length += length;
	return true;
}

static bool XMFixtureZeros(XMFixtureWriter *writer, size_t length)
{
	if (writer->length > sizeof(writer->bytes) ||
		length > sizeof(writer->bytes) - writer->length)
		return false;
	memset(writer->bytes + writer->length, 0, length);
	writer->length += length;
	return true;
}

static bool XMFixtureU8(XMFixtureWriter *writer, uint8_t value)
{
	return XMFixtureBytes(writer, &value, sizeof(value));
}

static bool XMFixtureLE16(XMFixtureWriter *writer, uint16_t value)
{
	uint8_t bytes[2] = {(uint8_t)value, (uint8_t)(value >> 8)};
	return XMFixtureBytes(writer, bytes, sizeof(bytes));
}

static bool XMFixtureLE32(XMFixtureWriter *writer, uint32_t value)
{
	uint8_t bytes[4] = {
		(uint8_t)value, (uint8_t)(value >> 8),
		(uint8_t)(value >> 16), (uint8_t)(value >> 24)
	};
	return XMFixtureBytes(writer, bytes, sizeof(bytes));
}

MADErr PPXMRunImportSelfTest(void)
{
	XMFixtureWriter writer = {0};
	static const char signature[] = "Extended Module: ";
	static const char songName[] = "XM import regression";
	static const char trackerName[] = "MachoPlayer selftest";
	static const char instrumentName[22] = "Envelope instrument";
	static const char sampleName[22] = "Delta loop sample";
	static const char sample16Name[22] = "16-bit delta sample";
	bool built =
		XMFixtureBytes(&writer, signature, 17) &&
		XMFixtureBytes(&writer, songName, 20) &&
		XMFixtureU8(&writer, 0x1A) &&
		XMFixtureBytes(&writer, trackerName, 20) &&
		XMFixtureLE16(&writer, 0x0104) &&
		XMFixtureLE32(&writer, HEADERSIZE) &&
		XMFixtureLE16(&writer, 2) && XMFixtureLE16(&writer, 0) &&
		XMFixtureLE16(&writer, 2) && XMFixtureLE16(&writer, 2) &&
		XMFixtureLE16(&writer, 1) && XMFixtureLE16(&writer, 1) &&
		XMFixtureLE16(&writer, 6) && XMFixtureLE16(&writer, 125) &&
		XMFixtureU8(&writer, 0) && XMFixtureU8(&writer, 1) &&
		XMFixtureZeros(&writer, 254);
	if (!built || writer.length != sizeof(XMHEADER))
		return MADUnknownErr;

	// Pattern 0: four rows, mixed packed/unpacked events, and XM-only effects.
	built =
		XMFixtureLE32(&writer, PHSIZE) && XMFixtureU8(&writer, 0) &&
		XMFixtureLE16(&writer, 4) && XMFixtureLE16(&writer, 18) &&
		XMFixtureU8(&writer, 49) && XMFixtureU8(&writer, 1) &&
		XMFixtureU8(&writer, 0) && XMFixtureU8(&writer, 0) &&
		XMFixtureU8(&writer, 0) && XMFixtureU8(&writer, 0x80) &&
		XMFixtureU8(&writer, 0x99) && XMFixtureU8(&writer, 97) &&
		XMFixtureU8(&writer, (uint8_t)('R' - 55)) && XMFixtureU8(&writer, 0x93) &&
		XMFixtureU8(&writer, 0x80) &&
		XMFixtureU8(&writer, 0x98) &&
		XMFixtureU8(&writer, (uint8_t)('X' - 55)) && XMFixtureU8(&writer, 0x12) &&
		XMFixtureU8(&writer, 0x80) &&
		XMFixtureU8(&writer, 0x84) && XMFixtureU8(&writer, 0xC8) &&
		XMFixtureU8(&writer, 0x80);
	// Pattern 1 deliberately has no packed data; its declared eight rows matter.
	built = built &&
		XMFixtureLE32(&writer, PHSIZE) && XMFixtureU8(&writer, 0) &&
		XMFixtureLE16(&writer, 8) && XMFixtureLE16(&writer, 0);

	// One instrument with volume/panning envelopes and 8/16-bit delta samples.
	built = built &&
		XMFixtureLE32(&writer, IHSIZE) &&
		XMFixtureBytes(&writer, instrumentName, sizeof(instrumentName)) &&
		XMFixtureU8(&writer, 0) && XMFixtureLE16(&writer, 2) &&
		XMFixtureLE32(&writer, IHSSIZE) &&
		XMFixtureZeros(&writer, 96) &&
		XMFixtureLE16(&writer, 0) && XMFixtureLE16(&writer, 64) &&
		XMFixtureLE16(&writer, 10) && XMFixtureLE16(&writer, 0) &&
		XMFixtureZeros(&writer, 40) &&
		XMFixtureLE16(&writer, 0) && XMFixtureLE16(&writer, 32) &&
		XMFixtureZeros(&writer, 44) &&
		XMFixtureU8(&writer, 2) && XMFixtureU8(&writer, 1) &&
		XMFixtureU8(&writer, 0) && XMFixtureU8(&writer, 0) &&
		XMFixtureU8(&writer, 1) && XMFixtureU8(&writer, 0) &&
		XMFixtureU8(&writer, 0) && XMFixtureU8(&writer, 0) &&
		XMFixtureU8(&writer, 7) && XMFixtureU8(&writer, 1) &&
		XMFixtureU8(&writer, 0) && XMFixtureU8(&writer, 0) &&
		XMFixtureU8(&writer, 5) && XMFixtureU8(&writer, 6) &&
		XMFixtureLE16(&writer, 256) && XMFixtureZeros(&writer, 22) &&
		XMFixtureLE32(&writer, 4) && XMFixtureLE32(&writer, 0) &&
		XMFixtureLE32(&writer, 4) && XMFixtureU8(&writer, 64) &&
		XMFixtureU8(&writer, 64) && XMFixtureU8(&writer, 1) &&
		XMFixtureU8(&writer, 128) && XMFixtureU8(&writer, 0xFF) &&
		XMFixtureU8(&writer, 0) &&
		XMFixtureBytes(&writer, sampleName, sizeof(sampleName)) &&
		XMFixtureLE32(&writer, 20) && XMFixtureLE32(&writer, 4) &&
		XMFixtureLE32(&writer, 12) && XMFixtureU8(&writer, 48) &&
		XMFixtureU8(&writer, 0xC0) && XMFixtureU8(&writer, 0x12) &&
		XMFixtureU8(&writer, 200) && XMFixtureU8(&writer, 2) &&
		XMFixtureU8(&writer, 0) &&
		XMFixtureBytes(&writer, sample16Name, sizeof(sample16Name));
	const uint8_t deltas[4] = {1, 1, 0xFF, 0xFF};
	built = built && XMFixtureBytes(&writer, deltas, sizeof(deltas)) &&
		XMFixtureLE16(&writer, 0x1234) &&
		XMFixtureLE16(&writer, 0x6DCB) &&
		XMFixtureLE16(&writer, 0x0001) &&
		XMFixtureLE16(&writer, 0x0001) &&
		XMFixtureLE16(&writer, 0x7FFE) &&
		XMFixtureLE16(&writer, 0x0001) &&
		XMFixtureLE16(&writer, 0x7FFF) &&
		XMFixtureLE16(&writer, 0x0001) &&
		XMFixtureLE16(&writer, 0x8000) &&
		XMFixtureLE16(&writer, 0xFFFF);
	if (!built)
		return MADUnknownErr;

	MADMusic *music = (MADMusic *)calloc(1, sizeof(MADMusic));
	if (music == NULL)
		return MADNeedMemory;
	struct staticXMData xmData = {0};
	if (!XM_Init(NULL, &xmData)) {
		free(music);
		return MADNeedMemory;
	}
	MADErr error = XM_Load((char *)writer.bytes, writer.length, music, NULL, &xmData);
	if (error == MADNoErr) {
		Cmd *note = GetMADCommand(0, 0, music->partition[0]);
		Cmd *retrig = GetMADCommand(1, 0, music->partition[0]);
		Cmd *extraFine = GetMADCommand(2, 0, music->partition[0]);
		Cmd *panning = GetMADCommand(3, 0, music->partition[0]);
		sData *sample = music->sample[0];
		sData *sample16 = music->sample[1];
		const int8_t decoded[4] = {1, 2, 1, 0};
		const int16_t decoded16[10] = {
			0x1234, 0x7FFF, INT16_MIN, -32767, -1,
			0, INT16_MAX, INT16_MIN, 0, -1
		};
		unsigned short expectedRate = (unsigned short)lrint(
			8363.0 * pow(2.0, (64.0 / 128.0) / 12.0));
		unsigned short expected16Rate = (unsigned short)lrint(
			8363.0 * pow(2.0, (-64.0 / 128.0) / 12.0));
		if (music->header == NULL || music->header->numPat != 2 ||
			music->header->numChn != 2 || music->header->numPointers != 2 ||
			music->header->numInstru != 1 || music->header->numSamples != 2 ||
			music->partition[0] == NULL || music->partition[0]->header.size != 4 ||
			music->partition[1] == NULL || music->partition[1]->header.size != 8 ||
			note->note != 48 || note->ins != 1 || note->vol != 0xFF ||
			retrig->note != 0xFE || retrig->cmd != MADEffectExtended ||
			retrig->arg != 0x93 || extraFine->cmd != MADEffectExtended ||
			extraFine->arg != 0x12 || panning->vol != 0xC8 ||
			music->fid[0].numSamples != 2 || music->fid[0].volSize != 2 ||
			music->fid[0].volEnv[0].val != 64 || music->fid[0].volEnd != 1 ||
			music->fid[0].volType !=
				(EFTypeOn | EFTypeSustain | EFTypeLoop) ||
			music->fid[0].pannSize != 1 || music->fid[0].pannEnv[0].val != 32 ||
			music->fid[0].vibDepth != 5 || music->fid[0].vibRate != 6 ||
			sample == NULL || sample->size != 4 || sample->loopBeg != 0 ||
			sample->loopSize != 4 || sample->loopType != MADLoopTypeClassic ||
			sample->vol != 64 || sample->c2spd != expectedRate ||
			sample->realNote != -1 ||
			memcmp(sample->data, decoded, sizeof(decoded)) != 0 ||
			sample16 == NULL || sample16->size != (int)sizeof(decoded16) ||
			sample16->loopBeg != 4 || sample16->loopSize != 12 ||
			sample16->loopType != MADLoopTypePingPong ||
			sample16->vol != 48 || sample16->amp != 16 ||
			sample16->c2spd != expected16Rate || sample16->realNote != 2 ||
			memcmp(sample16->data, decoded16, sizeof(decoded16)) != 0) {
			error = MADIncompatibleFile;
		}
	}
	XM_Cleanup(&xmData);
	MADDisposeMusic(&music, NULL);

	// The same fixture without its final sample byte must fail cleanly.
	MADMusic *truncatedMusic = (MADMusic *)calloc(1, sizeof(MADMusic));
	if (error == MADNoErr) {
		if (truncatedMusic == NULL) {
			error = MADNeedMemory;
		} else if (!XM_Init(NULL, &xmData)) {
			error = MADNeedMemory;
		} else {
			MADErr truncatedError = XM_Load((char *)writer.bytes,
				writer.length - 1, truncatedMusic, NULL, &xmData);
			if (truncatedError == MADNoErr)
				error = MADIncompatibleFile;
			XM_Cleanup(&xmData);
		}
	}
	if (truncatedMusic != NULL)
		MADDisposeMusic(&truncatedMusic, NULL);
	return error;
}

static MADErr TestXMFile(char* AlienFile, size_t fileSize, struct staticXMData *xmData)
{
	if (AlienFile != NULL && fileSize >= sizeof(XMHEADER) &&
		memcmp(AlienFile, "Extended Module: ", 17) == 0) {
		xmData->theXMRead = AlienFile;
		xmData->theXMMax = AlienFile + fileSize;
		
		/********************/
		/** READ XM HEADER **/
		/********************/
		
		READXMFILE(xmData->mh, sizeof(XMHEADER));
		/* BigEndian <-> LittleEndian */
		
		MADLE16(&xmData->mh->version);
		MADLE16(&xmData->mh->songlength);
		MADLE16(&xmData->mh->numchn);
		MADLE16(&xmData->mh->numpat);
		MADLE16(&xmData->mh->numins);
		MADLE32(&xmData->mh->headersize);
		
		switch (xmData->mh->version) {
			case 0x104:
				break;
				
			default:
				return MADFileNotSupportedByThisPlug;
				break;
		}
		if (xmData->mh->songname[20] != 0x1A ||
			xmData->mh->headersize < HEADERSIZE ||
			xmData->mh->headersize > fileSize - 60 ||
			xmData->mh->songlength == 0 || xmData->mh->songlength > UINT8_MAX ||
			xmData->mh->numchn == 0 || xmData->mh->numchn > UINT8_MAX ||
			xmData->mh->numpat == 0 || xmData->mh->numpat > MAXPATTERN ||
			xmData->mh->numins > MAXINSTRU)
			return MADFileNotSupportedByThisPlug;
		return MADNoErr;
	}
	return MADFileNotSupportedByThisPlug;
}

static MADErr ExtractXMInfo(MADInfoRec *info, void *AlienFile, size_t fileSize,
	struct staticXMData *xmData)
{
	int i;
	
	if (info == NULL || AlienFile == NULL || fileSize < sizeof(XMHEADER))
		return MADIncompatibleFile;
	xmData->theXMRead = AlienFile;
	xmData->theXMMax = (char *)AlienFile + fileSize;
	
	/********************/
	/** READ XM HEADER **/
	/********************/
	
	READXMFILE(xmData->mh, sizeof(XMHEADER));
	/* BigEndian <-> LittleEndian */
	
	MADLE16(&xmData->mh->version);
	MADLE16(&xmData->mh->songlength);
	MADLE16(&xmData->mh->numchn);
	MADLE16(&xmData->mh->numpat);
	MADLE16(&xmData->mh->numins);
	MADLE16(&xmData->mh->flags);
	
	switch(xmData->mh->version) {
		case 0x104:
			break;
			
		default:
			return MADFileNotSupportedByThisPlug;
			break;
	}
	
	/*** Signature ***/
	
	info->signature = 'XM  ';
	
	/*** Internal name ***/
	
	for (i = 0; i < 21; i++) {
		info->internalFileName[i] = xmData->mh->songname[i];
		if (info->internalFileName[i] == 0 || info->internalFileName[i] == 0x1a) {
			info->internalFileName[i] = 0;
			break;
		}
	}
	
	/*** Total Patterns ***/
	
	info->totalPatterns = xmData->mh->numpat;
	
	/*** Partition Length ***/
	
	info->partitionLength = xmData->mh->songlength;
	
	/*** Total Instruments ***/
	
	info->totalInstruments = xmData->mh->numins;
	
	/*** Total Tracks ***/
	
	info->totalTracks = xmData->mh->numchn;
	
	if (xmData->mh->flags & 1)
		strncpy(info->formatDescription, "XM Linear Plug", sizeof(info->formatDescription));
	else
		strncpy(info->formatDescription, "XM Log Plug", sizeof(info->formatDescription));
	
	return MADNoErr;
}

#ifndef _MAC_H

EXP MADErr FillPlug(PlugInfo *p);
EXP MADErr PPImpExpMain(MADFourChar order, char *AlienFileName, MADMusic *MadFile, MADInfoRec *info, MADDriverSettings *init);

EXP MADErr FillPlug(PlugInfo *p)		// Function USED IN DLL - For PC & BeOS
{
	strncpy(p->type, 		"XM  ", sizeof(p->type));
	strncpy(p->MenuName, 	"XM Files", sizeof(p->MenuName));
	p->mode	=	MADPlugImportExport;
	p->version = 2 << 16 | 0 << 8 | 0;
	
	return MADNoErr;
}
#endif

#if defined(EMBEDPLUGS) && EMBEDPLUGS
MADErr mainXM(MADFourChar order, char *AlienFileName, MADMusic *MadFile, MADInfoRec *info, MADDriverSettings *init)
#else
extern MADErr PPImpExpMain(MADFourChar order, char *AlienFileName, MADMusic *MadFile, MADInfoRec *info, MADDriverSettings *init)
#endif
{
	MADErr	myErr = MADNoErr;
	void*	AlienFile;
	long	sndSize;
	UNFILE	iFileRefI;
	struct staticXMData xmData = {0};
	
	if (!XM_Init(init, &xmData))
		return MADNeedMemory;
	
	switch (order) {
#if !defined(NOEXPORTMUSIC) || NOEXPORTMUSIC == 0
		case MADPlugExport:
			AlienFile = ConvertMad2XM(MadFile, init, &sndSize, &xmData);
			
			if (AlienFile != NULL) {
				iFileCreate(AlienFileName, 'XM  ');
				iFileRefI = iFileOpenWrite(AlienFileName);
				if (iFileRefI) {
					iWrite(sndSize, AlienFile, iFileRefI);
					iClose(iFileRefI);
				} else {
					myErr = MADWritingErr;
				}
				free(AlienFile);
				AlienFile = NULL;
			} else
				myErr = MADNeedMemory;
			break;
#endif
			
		case MADPlugImport:
			iFileRefI = iFileOpenRead(AlienFileName);
			if (iFileRefI) {
				sndSize = iGetEOF(iFileRefI);
				
				AlienFile = sndSize > 0 ? malloc((size_t)sndSize) : NULL;
				if (AlienFile == NULL) {
					myErr = sndSize <= 0 ? MADReadingErr : MADNeedMemory;
				} else {
					myErr = iRead(sndSize, AlienFile, iFileRefI);
					if (myErr == MADNoErr) {
						myErr = TestXMFile(AlienFile, (size_t)sndSize, &xmData);
						if (myErr == MADNoErr) {
							myErr = XM_Load(AlienFile, (size_t)sndSize,
								MadFile, init, &xmData);
						}
					}
					free(AlienFile); AlienFile = NULL;
				}
				iClose(iFileRefI);
			} else
				myErr = MADReadingErr;
			break;
			
		case MADPlugTest:
			iFileRefI = iFileOpenRead(AlienFileName);
			if (iFileRefI) {
				long fileSize = iGetEOF(iFileRefI);
				sndSize = XM_MIN(fileSize, 1024);
				
				AlienFile = sndSize > 0 ? malloc((size_t)sndSize) : NULL;
				if (AlienFile == NULL) {
					myErr = fileSize <= 0 ? MADReadingErr : MADNeedMemory;
				} else {
					myErr = iRead(sndSize, AlienFile, iFileRefI);
					
					if (myErr == MADNoErr)
						myErr = TestXMFile(AlienFile, (size_t)sndSize, &xmData);
					
					free(AlienFile); AlienFile = NULL;
				}
				iClose(iFileRefI);
			} else
				myErr = MADReadingErr;
			break;
			
		case MADPlugInfo:
			iFileRefI = iFileOpenRead(AlienFileName);
			if (iFileRefI) {
				info->fileSize = iGetEOF(iFileRefI);
				
				sndSize = XM_MIN((long)info->fileSize, 5000L);
				
				AlienFile = sndSize > 0 ? malloc((size_t)sndSize) : NULL;
				if (AlienFile == NULL)
					myErr = info->fileSize <= 0 ? MADReadingErr : MADNeedMemory;
				else {
					myErr = iRead(sndSize, AlienFile, iFileRefI);
					if (myErr == MADNoErr) {
						myErr = TestXMFile(AlienFile, (size_t)sndSize, &xmData);
						if (!myErr)
							myErr = ExtractXMInfo(info, AlienFile,
								(size_t)sndSize, &xmData);
					}
					free(AlienFile); AlienFile = NULL;
				}
				iClose(iFileRefI);
			} else
				myErr = MADReadingErr;
			break;
			
		default:
			myErr = MADOrderNotImplemented;
			break;
	}
	
	XM_Cleanup(&xmData);
	
	return myErr;
}
