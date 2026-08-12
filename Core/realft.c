/********************						***********************/
//
//	Player PRO 5.9 - DRIVER SOURCE CODE -
//
//	Library Version 5.9
//
//	To use with MAD Library for Mac: Symantec, CodeWarrior and MPW
//
//	Antoine ROSSET
//	20 Micheli-Du-Crest
//	1205 GENEVA
//	SWITZERLAND
//
//	COPYRIGHT ANTOINE ROSSET 1996, 1997, 1998, 1999, 2000, 2001, 2002
//
//	Thank you for your interest in PlayerPRO !
//
//	FAX:			(+41 22) 346 11 97
//	PHONE: 			(+41 79) 203 74 62
//	Internet: 		RossetAntoine@bluewin.ch
//
/********************						***********************/

#define _USE_MATH_DEFINES
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "RDriver.h"
#include "RDriverInt.h"
#include "MADPrivate.h"

#define OUTPUT_EQ_FFT_SIZE	(EQPACKET * 2)
#define OUTPUT_EQ_HOP_SIZE	(EQPACKET)
#define OUTPUT_EQ_CHANNELS	2

typedef struct MADOutputEqualizerState {
	double previous[OUTPUT_EQ_CHANNELS][OUTPUT_EQ_HOP_SIZE];
	double incoming[OUTPUT_EQ_CHANNELS][OUTPUT_EQ_HOP_SIZE];
	double overlap[OUTPUT_EQ_CHANNELS][OUTPUT_EQ_HOP_SIZE];
	double output[OUTPUT_EQ_CHANNELS][OUTPUT_EQ_HOP_SIZE];
	double fft[OUTPUT_EQ_FFT_SIZE + 2];
	size_t inputCount;
	size_t outputRead;
	size_t outputCount;
	bool active;
} MADOutputEqualizerState;

static double EQInterpolate(double p, double p1, double p2, double v1, double v2)
{
	double dp,dv,di;
	
	if (p1 == p2) return v1;
	
	dv=v2-v1;
	dp=p2-p1;
	di=p-p1;
	
	return v1 + ((di*dv) / dp);
}

MADErr MADInitEqualizer(MADDriverRec *intDriver)
{
	int i;
	
	intDriver->Filter = (double*)calloc(sizeof(double) * ((EQPACKET*2)+2), 1);
	intDriver->fData  = (double*)calloc(sizeof(double) * ((EQPACKET*2)+2), 1);
	intDriver->outputEqualizerState = calloc(1, sizeof(MADOutputEqualizerState));
	
	if (intDriver->Filter == NULL)
		return MADNeedMemory;
	if (intDriver->fData == NULL) {
		free(intDriver->Filter);
		intDriver->Filter = NULL;
		free(intDriver->outputEqualizerState);
		intDriver->outputEqualizerState = NULL;
		return MADNeedMemory;
	}
	if (intDriver->outputEqualizerState == NULL) {
		free(intDriver->Filter);
		free(intDriver->fData);
		intDriver->Filter = NULL;
		intDriver->fData = NULL;
		return MADNeedMemory;
	}
	
	for (i = 0; i <= EQPACKET * 2; i++) {
		intDriver->Filter[i] = 1.0;
	}
	
	return MADNoErr;
}

void MADCloseEqualizer(MADDriverRec *intDriver)
{
	if (intDriver == NULL) return;
	free(intDriver->Filter);
	free(intDriver->fData);
	free(intDriver->outputEqualizerState);
	intDriver->Filter = NULL;
	intDriver->fData = NULL;
	intDriver->outputEqualizerState = NULL;
}

void MADResetOutputEqualizer(MADDriverRec *intDriver)
{
	if (intDriver == NULL || intDriver->outputEqualizerState == NULL) return;
	memset(intDriver->outputEqualizerState, 0, sizeof(MADOutputEqualizerState));
}

static bool MADOutputEqualizerIsUnity(const MADDriverRec *intDriver)
{
	if (intDriver == NULL || intDriver->Filter == NULL) return true;
	for (size_t bin = 0; bin <= OUTPUT_EQ_FFT_SIZE; bin++) {
		if (fabs(intDriver->Filter[bin] - 1.0) > 0.0000001) return false;
	}
	return true;
}

static double MADOutputEqualizerWindow(size_t sample)
{
	/*
	 * A square-root Hann pair gives constant-power reconstruction at a
	 * 50-percent overlap: w[n]^2 + w[n + N/2]^2 == 1.
	 */
	return sin(M_PI * ((double)sample + 0.5) / (double)OUTPUT_EQ_FFT_SIZE);
}

static void MADRenderOutputEqualizerFrame(MADDriverRec *intDriver,
	MADOutputEqualizerState *state, short channelCount)
{
	for (short channel = 0; channel < channelCount; channel++) {
		for (size_t sample = 0; sample < OUTPUT_EQ_HOP_SIZE; sample++) {
			state->fft[sample + 1] =
				state->previous[channel][sample] * MADOutputEqualizerWindow(sample);
			state->fft[sample + OUTPUT_EQ_HOP_SIZE + 1] =
				state->incoming[channel][sample] *
				MADOutputEqualizerWindow(sample + OUTPUT_EQ_HOP_SIZE);
		}

		MADrealft(state->fft, OUTPUT_EQ_FFT_SIZE / 2, true);

		/* Numerical Recipes realft stores DC and Nyquist separately. */
		state->fft[1] *= intDriver->Filter[0];
		state->fft[2] *= intDriver->Filter[OUTPUT_EQ_FFT_SIZE];
		for (size_t bin = 1; bin < OUTPUT_EQ_FFT_SIZE / 2; bin++) {
			double gain = intDriver->Filter[bin * 2];
			state->fft[bin * 2 + 1] *= gain;
			state->fft[bin * 2 + 2] *= gain;
		}

		MADrealft(state->fft, OUTPUT_EQ_FFT_SIZE / 2, false);

		for (size_t sample = 0; sample < OUTPUT_EQ_HOP_SIZE; sample++) {
			double first = state->fft[sample + 1] /
				(double)(OUTPUT_EQ_FFT_SIZE / 2);
			double second = state->fft[sample + OUTPUT_EQ_HOP_SIZE + 1] /
				(double)(OUTPUT_EQ_FFT_SIZE / 2);
			state->output[channel][sample] =
				state->overlap[channel][sample] +
				first * MADOutputEqualizerWindow(sample);
			state->overlap[channel][sample] =
				second * MADOutputEqualizerWindow(sample + OUTPUT_EQ_HOP_SIZE);
			state->previous[channel][sample] = state->incoming[channel][sample];
		}
	}
	state->inputCount = 0;
	state->outputRead = 0;
	state->outputCount = OUTPUT_EQ_HOP_SIZE;
	state->active = true;
}

static double MADClampOutputSample(double sample, double minimum, double maximum)
{
	if (sample < minimum) return minimum;
	if (sample > maximum) return maximum;
	return sample;
}

void MADProcessOutputEqualizer(MADDriverRec *intDriver, void *sampleData,
	size_t frameCount)
{
	if (intDriver == NULL || sampleData == NULL || frameCount == 0 ||
		!intDriver->base.Equalizer || intDriver->outputEqualizerState == NULL ||
		intDriver->Filter == NULL) {
		return;
	}

	MADOutputEqualizerState *state =
		(MADOutputEqualizerState*)intDriver->outputEqualizerState;

	/*
	 * A flat equalizer must be a bit-for-bit bypass. Besides avoiding needless
	 * work, this prevents latency or startup silence when the original 100%
	 * preset is selected.
	 */
	if (MADOutputEqualizerIsUnity(intDriver)) {
		if (state->active || state->inputCount != 0 || state->outputCount != 0) {
			MADResetOutputEqualizer(intDriver);
		}
		return;
	}

	short channelCount =
		intDriver->DriverSettings.outPutMode == MonoOutPut ? 1 : 2;
	if (intDriver->DriverSettings.outPutBits == 16) {
		int16_t *samples = (int16_t*)sampleData;
		for (size_t frame = 0; frame < frameCount; frame++) {
			for (short channel = 0; channel < channelCount; channel++) {
				double output = state->outputCount > 0 ?
					state->output[channel][state->outputRead] : 0.0;
				state->incoming[channel][state->inputCount] =
					samples[frame * channelCount + channel];
				samples[frame * channelCount + channel] = (int16_t)lrint(
					MADClampOutputSample(output, -32768.0, 32767.0));
			}
			if (state->outputCount > 0) {
				state->outputRead++;
				state->outputCount--;
			}
			state->inputCount++;
			if (state->inputCount == OUTPUT_EQ_HOP_SIZE) {
				MADRenderOutputEqualizerFrame(intDriver, state, channelCount);
			}
		}
	} else if (intDriver->DriverSettings.outPutBits == 8) {
		int8_t *samples = (int8_t*)sampleData;
		for (size_t frame = 0; frame < frameCount; frame++) {
			for (short channel = 0; channel < channelCount; channel++) {
				double output = state->outputCount > 0 ?
					state->output[channel][state->outputRead] : 0.0;
				state->incoming[channel][state->inputCount] =
					samples[frame * channelCount + channel];
				samples[frame * channelCount + channel] = (int8_t)lrint(
					MADClampOutputSample(output, -128.0, 127.0));
			}
			if (state->outputCount > 0) {
				state->outputRead++;
				state->outputCount--;
			}
			state->inputCount++;
			if (state->inputCount == OUTPUT_EQ_HOP_SIZE) {
				MADRenderOutputEqualizerFrame(intDriver, state, channelCount);
			}
		}
	}
}

#define SWAP(a,b) tempr=(a);(a)=(b);(b)=tempr

static void MADfour1(double *data, int nn, int isign)
{
	int 		n, mmax, m, j, istep, i;
	double 		wtemp, wr, wpr, wpi, wi, theta;
	double 		tempr, tempi;
	
	n = nn << 1;
	j = 1;
	for (i = 1; i < n; i += 2) {
		if (j > i) {
			SWAP(data[j], data[i]);
			SWAP(data[j+1], data[i+1]);
		}
		m = n >> 1;
		while (m >= 2 && j > m) {
			j -= m;
			m >>= 1;
		}
		j += m;
	}
	mmax = 2;
	while (n > mmax) {
		istep = 2 * mmax;
		
		theta = M_PI / (isign * mmax);
		wtemp = sin(theta);
		wpr = -2.0 * wtemp * wtemp;
		wpi = sin(2.0 * theta);
		wr = 1.0;
		wi = 0.0;
		for (m = 1; m < mmax; m += 2) {
			for (i = m; i <= n; i += istep) {
				j = i + mmax;
				tempr = wr * data[j] - wi*data[j + 1];
				tempi = wr * data[j + 1] + wi * data[j];
				data[j] = data[i] - tempr;
				data[j + 1] = data[i + 1] - tempi;
				data[i] += tempr;
				data[i+1] += tempi;
			}
			wr = (wtemp = wr) * wpr - wi * wpi + wr;
			wi = wi * wpr + wtemp * wpi + wi;
		}
		mmax = istep;
	}
}

#undef SWAP

void MADrealft(double *data,int n,int isign)
{
	int 		i, i1, i2, i3, i4, n2p3;
	double 		c1 = 0.5, c2, h1r, h1i, h2r, h2i;
	double 		wr, wi, wpr, wpi, wtemp, theta;
	
	theta = M_PI / (double) n;
	if (isign == 1) {
		c2 = -0.5;
		MADfour1(data, n, 1);
	} else {
		c2 = 0.5;
		theta = -theta;
	}
	wtemp = sin(0.5 * theta);
	wpr = -2.0 * wtemp * wtemp;
	wpi = sin(theta);
	wr = 1.0 + wpr;
	wi = wpi;
	n2p3 = 2 * n + 3;
	for (i = 2; i <= n / 2; i++) {
		i4 = 1 + (i3 = n2p3 - (i2 = 1 + (i1 = i + i - 1)));
		h1r = c1 * (data[i1] + data[i3]);
		h1i = c1 * (data[i2] - data[i4]);
		h2r = -c2 * (data[i2] + data[i4]);
		h2i= c2 * (data[i1] - data[i3]);
		data[i1] = h1r + wr * h2r - wi * h2i;
		data[i2] = h1i + wr * h2i + wi * h2r;
		data[i3] = h1r - wr * h2r + wi * h2i;
		data[i4] = -h1i + wr * h2i + wi * h2r;
		wr = (wtemp = wr) * wpr - wi * wpi + wr;
		wi = wi * wpr + wtemp * wpi + wi;
	}
	if (isign == 1) {
		data[1] = (h1r = data[1]) + data[2];
		data[2] = h1r - data[2];
	} else {
		data[1] = c1 * ((h1r = data[1]) + data[2]);
		data[2] = c1 * (h1r - data[2]);
		MADfour1(data, n, -1);
	}
}

/*
void twofft(double *data1,double *data2,double *fft1,double *fft2, int n)
{
	int nn3,nn2,jj,j;
	double rep,rem,aip,aim;
	
	nn3=1+(nn2=2+n+n);
	for (j=1,jj=2;j<=n;j++,jj+=2) {
		fft1[jj-1]=data1[j];
		fft1[jj]=data2[j];
	}
	MADfour1(fft1,n,1);
	fft2[1]=fft1[2];
	fft1[2]=fft2[2]=0.0;
	for (j=3;j<=n+1;j+=2) {
		rep=0.5*(fft1[j]+fft1[nn2-j]);
		rem=0.5*(fft1[j]-fft1[nn2-j]);
		aip=0.5*(fft1[j+1]+fft1[nn3-j]);
		aim=0.5*(fft1[j+1]-fft1[nn3-j]);
		fft1[j]=rep;
		fft1[j+1]=aim;
		fft1[nn2-j]=rep;
		fft1[nn3-j] = -aim;
		fft2[j]=aip;
		fft2[j+1] = -rem;
		fft2[nn2-j]=aip;
		fft2[nn3-j]=rem;
	}
}
*/

void MADCallFFT(sData *SData, double *filter, MADDriverRec *intDriver, bool shift)
{
	if (filter == NULL) filter = intDriver->Filter;
	
	switch(SData->amp)
	{
		case 8:
			if (SData->stereo) FFT8S(SData->data, SData->size, filter, intDriver, 2, shift);
			else FFT8S(SData->data, SData->size, filter, intDriver, 1, shift);
			break;
			
		case 16:
			if (SData->stereo) FFT16S((short*) SData->data, SData->size, filter, intDriver, 2, shift);
			else FFT16S((short*) SData->data, SData->size, filter, intDriver, 1, shift);
			break;
	}
}

void FFT8S(char* SData, size_t size, double *filter, MADDriverRec *intDriver, short nochan, bool shift)
{
	int		y, powersize;
	int		*shiftAr = NULL;
	double	pente, axe, *fDataCopy2 = NULL, *fDataCopy = intDriver->fData;
	bool	didInitFData = false;
	size_t	i;
	
	if (nochan == 2) {	// STEREO
		if (size != EQPACKET*2*2) {
			powersize = 1;
			do {
				powersize *= 2;
			} while (powersize < size/2);
			
			fDataCopy = (double*)malloc(sizeof(double) * (powersize+2));
			didInitFData = 1;
		} else
			powersize = EQPACKET*2;
	} else {
		if (size != EQPACKET*2) {
			powersize = 1;
			do {
				powersize *= 2;
			} while (powersize < size);
			
			fDataCopy = (double*)malloc(sizeof(double) * (powersize+2));
			didInitFData = 1;
		} else
			powersize = EQPACKET*2;
	}
	
	if (shift) {
		fDataCopy2 = (double*) malloc(sizeof(double) * (powersize+2));
		if (fDataCopy2 == NULL) {
			if (didInitFData && fDataCopy) {
				free(fDataCopy);
			}
			return;
		}
		
		shiftAr = (int*)calloc(sizeof(int), powersize + 2);
		if (shiftAr == NULL) {
			if (didInitFData && fDataCopy) {
				free(fDataCopy);
			}
			free(fDataCopy2);
			return;
		}
	}
	
	if (fDataCopy == NULL) {
		if(shiftAr)
			free(shiftAr);
		if(fDataCopy2)
			free(fDataCopy2);
		return;
	}
	
	for (y = 0; y < nochan; y++) {
		// Copy data
		
		if (nochan == 2) {	// STEREO
			if (powersize * 2 > size) {
				for (i = 0 ; i < size/2; i++)
					fDataCopy[i + 1] = SData[2 * i];
				for (i = size / 2 ; i < powersize; i++)
					fDataCopy[i + 1] = 0;
			} else {
				for (i = 0; i < powersize; i++)
					fDataCopy[i + 1] = SData[2 * i];
			}
		} else {				// MONO
			if (powersize > size) {
				for (i = 0 ; i < size; i++)
					fDataCopy[i + 1] = SData[i];
				for (i = size ; i < powersize; i++)
					fDataCopy[i + 1] = 0;
			} else {
				for (i = 0 ; i < powersize; i++)
					fDataCopy[i + 1] = SData[i];
			}
		}
		
		// First and last values MUST be zero! // ** //  // ** //  // ** //
		pente = (fDataCopy[powersize] - fDataCopy[1]) / (double) (powersize -1);
		axe = fDataCopy[1];
		
		for (i = 1 ; i <= powersize; i++) {
			fDataCopy[i] -= (axe + (double)(i-1) * pente);
		}
		// ** //  // ** //  // ** //  // ** //  // ** //  // ** //  // ** //
		
		MADrealft(fDataCopy, powersize/2, true);
		
		if (shift) {
			int a;
			
			for (i = 0 ; i < powersize; i++) {
				a = (int)((i * EQPACKET*2) / powersize);
				
				if (a + 1 < powersize) {
					shiftAr[i] = (EQInterpolate((double)(i * EQPACKET * 2) / (double)powersize, a, a + 1, filter[a], filter[a + 1]) * powersize) / (EQPACKET * 2);
				} else {
					shiftAr[i] = (filter[a] * powersize) / (EQPACKET * 2);
				}
				fDataCopy2[i] = 0;
			}
			
			for (i = 0 ; i < powersize; i++) {
				if (shiftAr[i] >= 0 && shiftAr[i] < powersize)
					fDataCopy2[shiftAr[i] + 1] += fDataCopy[i + 1];
			}
			
			memcpy(fDataCopy, fDataCopy2, sizeof(double) * (powersize + 2));
		} else {
			if (size != EQPACKET * 2 * 2) {
				for (i = 0 ; i < powersize; i++)
					fDataCopy[i + 1] *= filter[(i * EQPACKET * 2) / powersize];
			} else {
				for (i = 0 ; i < powersize; i++)
					fDataCopy[i + 1] *= filter[i];
			}
		}
		
		MADrealft(fDataCopy, powersize / 2, false);
		
		// First and last values MUST be zero! // ** //  // ** //  // ** //
		pente = (fDataCopy[powersize] - fDataCopy[1]) / (double) (powersize -1);
		axe = fDataCopy[1];
		
		for (i = 1 ; i <= powersize; i++) {
			fDataCopy[i] -= (axe + (double)(i - 1) * pente);
		}
		// ** //  // ** //  // ** //  // ** //  // ** //  // ** //  // ** //
		
		for (i = 1 ; i <= powersize; i++)
			fDataCopy[i] /= powersize / 2;
		
		// Check data
		for (i = 1 ; i <= powersize; i++) {
			if (fDataCopy[i] > 127)
				fDataCopy[i] = 127;
			if (fDataCopy[i] < -127)
				fDataCopy[i] = -127;
		}
		
		// Restore data
		if (nochan == 2) {	// STEREO
			if (powersize * 2 > size) {
				for (i = 0 ; i < size / 2; i++)
					SData[2 * i] = fDataCopy[i + 1];
			} else {
				for (i = 0 ; i < powersize; i++)
					SData[2 * i] = fDataCopy[i + 1];
			}
		} else {				// MONO
			if (powersize > size) {
				for (i = 0 ; i < size; i++)
					SData[i] = fDataCopy[i + 1];
			} else {
				for (i = 0 ; i < powersize; i++)
					SData[i] = fDataCopy[i + 1];
			}
		}
		
		//// *********************** Now the left channel !
		
		SData++;
	}
	
	if (nochan == 2)
		SData -= 2;
	else
		SData--;
	
	if (size != EQPACKET*2*2) {
		free(fDataCopy);
		fDataCopy = NULL;
		
		if (shift) {
			free(fDataCopy2);
			free(shiftAr);
		}
	}
}

//static long PreviousAxe[2];
//static long PreviousAxe2[2];

void FFT16S(short* SData, size_t size, double *filter, MADDriverRec *intDriver, short nochan, bool shift)
{
	int		y, powersize, *shiftAr = NULL;
	double	pente, axe, *fDataCopy2 = NULL, *fDataCopy = intDriver->fData;
	bool	didInitFData = false;
	size_t	i;
	
	size /= 2;
	
	if (nochan == 2) {	// STEREO
		if (size != EQPACKET * 2 * 2) {
			powersize = 1;
			do {
				powersize *= 2;
			} while (powersize < size/2);
			
			fDataCopy = (double*)malloc(sizeof(double) * (powersize + 2));
			didInitFData = 1;
		} else
			powersize = EQPACKET * 2 * 2;
	} else {
		if (size != EQPACKET*2) {
			powersize = 1;
			do {
				powersize *= 2;
			} while (powersize < size);
			
			fDataCopy = (double*)malloc(sizeof(double) * (powersize + 2));
			didInitFData = 1;
		} else
			powersize = EQPACKET * 2;
	}
	
	if (shift) {
		fDataCopy2 = (double*) malloc(sizeof(double) * (powersize + 2));
		if (fDataCopy2 == NULL) {
			if (didInitFData && fDataCopy) {
				free(fDataCopy);
			}
			return;
		}
		
		shiftAr = (int*)calloc(sizeof(int) * (powersize + 2), 1);
		if (shiftAr == NULL) {
			if (didInitFData && fDataCopy) {
				free(fDataCopy);
			}
			free(fDataCopy2);
			return;
		}
	}
	
	if (fDataCopy == NULL) {
		if(shiftAr)
			free(shiftAr);
		if(fDataCopy2)
			free(fDataCopy2);
		return;
	}
	
	for (y = 0; y < nochan; y++) {
		// Copy data
		
		if (nochan == 2) {	// STEREO
			if (powersize*2 > size) {
				for (i = 0; i < size/2; i++)
					fDataCopy[i + 1] = SData[2 * i];
				for (i = size / 2 ; i < powersize; i++)
					fDataCopy[i + 1] = 0;
			} else {
				for (i = 0; i < powersize; i++)
					fDataCopy[i + 1] = SData[2 * i];
			}
		} else {				// MONO
			if (powersize > size) {
				for (i = 0; i < size; i++)
					fDataCopy[i + 1] = SData[i];
				for (i = size; i < powersize; i++)
					fDataCopy[i + 1] = 0;
			} else {
				for (i = 0; i < powersize; i++)
					fDataCopy[i + 1] = SData[i];
			}
		}
		
		// First and last values MUST be zero! // ** //  // ** //  // ** //
		
		pente = (fDataCopy[powersize] - fDataCopy[1]) / (double) (powersize -1);
		axe = fDataCopy[1];
		
		for (i = 1 ; i <= powersize; i++) {
			fDataCopy[i] -= (axe + (double)(i - 1) * pente);
		}
		// ** //  // ** //  // ** //  // ** //  // ** //  // ** //  // ** //
		
		MADrealft(fDataCopy, powersize/2, true);
		
		if (shift) {
			int a, b;
			
			for (i = 0; i < powersize; i++) {
				a = (int)((i * EQPACKET * 2) / powersize);
				b = a+1;
				
				shiftAr[i] = (EQInterpolate((double)(i * EQPACKET * 2) / (double)powersize, a, a + 1, filter[a], filter[a + 1]) * powersize) / (EQPACKET * 2);
				fDataCopy2[i] = 0;
			}
			
			for (i = 0; i < powersize; i++) {
				if (shiftAr[i] >= 0 && shiftAr[i] < powersize)
					fDataCopy2[shiftAr[i] + 1] += fDataCopy[i + 1];
			}
			
			memcpy(fDataCopy, fDataCopy2, sizeof(double) * (powersize + 2));
		} else {
			if (size != EQPACKET * 2 * 2) {
				for (i = 0 ; i < powersize; i++)
					fDataCopy[i + 1] *= filter[(i * EQPACKET * 2) / powersize];
			} else {
				for (i = 0 ; i < powersize; i++)
					fDataCopy[i + 1] *= filter[i];
			}
		}
		
		MADrealft(fDataCopy, powersize / 2, false);
		
		for (i = 1 ; i <= powersize; i++)
			fDataCopy[i] /= powersize / 2;
		
		// First and last values MUST be zero! // ** //  // ** //  // ** //
		pente = (fDataCopy[powersize] - fDataCopy[1]) / (double)(powersize - 1);
		axe = fDataCopy[1];
		
		for (i = 1 ; i <= powersize; i++) {
			fDataCopy[i] -= (axe + (double)(i - 1) * pente);
		}
		// ** //  // ** //  // ** //  // ** //  // ** //  // ** //  // ** //
		
		// Check data
		for (i = 1 ; i <= powersize; i++) {
			if (fDataCopy[i] > 32767)
				fDataCopy[i] = 32767;
			if (fDataCopy[i] < -32767)
				fDataCopy[i] = -32767;
		}
		
		// Restore data
		if (nochan == 2) {	// STEREO
			if (powersize * 2 > size) {
				for (i = 0; i < size / 2; i++)
					SData[2 * i] = fDataCopy[i + 1];
			} else {
				for (i = 0; i < powersize; i++)
					SData[2 * i] = fDataCopy[i + 1];
			}
		} else {				// MONO
			if (powersize > size) {
				for (i = 0 ; i < size; i++)
					SData[i] = fDataCopy[i + 1];
			} else {
				for (i = 0 ; i < powersize; i++)
					SData[i] = fDataCopy[i + 1];
			}
		}
		
		//// *********************** Now the left channel !
		
		SData++;
	}
	
	if (nochan == 2)
		SData -= 2;
	else
		SData--;
	
	if (size != EQPACKET * 2 * 2) {
		free(fDataCopy);
		fDataCopy = NULL;
		
		if (shift) {
			free(fDataCopy2);
			free(shiftAr);
		}
	}
}
