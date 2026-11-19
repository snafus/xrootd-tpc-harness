/*
 * Loaded into the destination server with LD_PRELOAD.  It makes libcurl fail
 * to copy a request handle, as it does when the server runs out of memory.
 * A multi-stream pull copies its first handle once for every other handle it
 * needs; a single-stream pull copies none.
 */
#include <stddef.h>

void *curl_easy_duphandle(void *handle)
{
	(void)handle;
	return NULL;
}
