// SPDX-License-Identifier: MIT
// Copyright (c) 2018 Alex Barney

// LibAtrac9's utility.c with defined boundary shifts. The upstream expression
// `value >> (32 - bitCount)` shifts by the type width when bitCount is zero;
// that is undefined C even though x86 happens to mask the shift count.

#include "utility.h"
#include <limits.h>
#include <string.h>

int Max(int a, int b) { return a > b ? a : b; }
int Min(int a, int b) { return a > b ? b : a; }

unsigned int BitReverse32(unsigned int value, int bitCount)
{
    value = ((value & 0xaaaaaaaa) >> 1) | ((value & 0x55555555) << 1);
    value = ((value & 0xcccccccc) >> 2) | ((value & 0x33333333) << 2);
    value = ((value & 0xf0f0f0f0) >> 4) | ((value & 0x0f0f0f0f) << 4);
    value = ((value & 0xff00ff00) >> 8) | ((value & 0x00ff00ff) << 8);
    value = (value >> 16) | (value << 16);
    if (bitCount <= 0) return 0;
    if (bitCount >= 32) return value;
    return value >> (32 - bitCount);
}

int SignExtend32(int value, int bits)
{
    if (bits <= 0) return 0;
    if (bits >= 32) return value;
    const unsigned int sign = 1u << (bits - 1);
    const unsigned int extended = ((unsigned int)value ^ sign) - sign;
    int result;
    memcpy(&result, &extended, sizeof(result));
    return result;
}

short Clamp16(int value)
{
    if (value > SHRT_MAX) return SHRT_MAX;
    if (value < SHRT_MIN) return SHRT_MIN;
    return (short)value;
}

int Round(double x)
{
    x += 0.5;
    return (int)x - (x < (int)x);
}
