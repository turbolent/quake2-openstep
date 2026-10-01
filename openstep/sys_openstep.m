#include <libc.h>
#import <AppKit/AppKit.h>
#include "../qcommon/qcommon.h"

int		curtime;
int		sys_frame_time;
qboolean stdin_active = true;

void	Sys_UnloadGame (void)
{
}

void *GetGameAPI (void *import);

void	*Sys_GetGameAPI (void *parms)
{
	// we are hard-linked in, so no need to load anything
    return GetGameAPI (parms);
}

void Sys_CopyProtect (void)
{
}

char *Sys_GetClipboardData( void )
{
    return NULL;
}

#ifdef NeXT
extern char **environ;

char *strdup (const char *string)
{
    char *copy;
    size_t length;

    length = strlen (string) + 1;
    copy = malloc (length);
    if (!copy)
        return NULL;

    memcpy (copy, string, length);
    return copy;
}

int putenv (const char *string)
{
    char **ep;
    char **new_environ;
    char *entry_copy;
    const char *name_end;
    size_t name_len;
    int env_count;

    name_end = strchr (string, '=');
    if (name_end)
        name_len = (size_t)(name_end - string);
    else
        name_len = strlen (string);

    ep = environ;
    while (ep && *ep)
    {
        if (strncmp (*ep, string, name_len) == 0 && (*ep)[name_len] == '=')
            break;
        ep++;
    }

    if (!name_end)
    {
        if (!ep || !*ep)
            return 0;

        do
        {
            ep[0] = ep[1];
            ep++;
        } while (ep[0]);
        return 0;
    }

    entry_copy = strdup (string);
    if (!entry_copy)
        return -1;

    if (ep && *ep)
    {
        *ep = entry_copy;
        return 0;
    }

    env_count = 0;
    if (environ)
    {
        while (environ[env_count])
            env_count++;
    }

    new_environ = malloc ((env_count + 2) * sizeof(*new_environ));
    if (!new_environ)
    {
        free(entry_copy);
        return -1;
    }

    if (environ && env_count)
        memcpy (new_environ, environ, env_count * sizeof(*new_environ));

    new_environ[env_count] = entry_copy;
    new_environ[env_count + 1] = NULL;
    environ = new_environ;
    return 0;
}
#endif


//===========================================================================

int		hunkcount;

byte	*membase;
int		hunkmaxsize;
int		cursize;

//#define	VIRTUAL_ALLOC

void *Hunk_Begin (int maxsize)
{
    // reserve a huge chunk of memory, but don't commit any yet
    cursize = 0;
    hunkmaxsize = maxsize;
#ifdef VIRTUAL_ALLOC
    membase = VirtualAlloc (NULL, maxsize, MEM_RESERVE, PAGE_NOACCESS);
#else
    membase = malloc (maxsize);

#endif
    if (!membase)
        Sys_Error ("VirtualAlloc reserve failed");
    memset (membase, 0, maxsize);
    return (void *)membase;
}

void *Hunk_Alloc (int size)
{
    void	*buf;

    // round to cacheline
    size = (size+31)&~31;

#ifdef VIRTUAL_ALLOC
    // commit pages as needed
//	buf = VirtualAlloc (membase+cursize, size, MEM_COMMIT, PAGE_READWRITE);
    buf = VirtualAlloc (membase, cursize+size, MEM_COMMIT, PAGE_READWRITE);
    if (!buf)
    {
        FormatMessage(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM, NULL, GetLastError(), MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), (LPTSTR) &buf, 0, NULL);
        Sys_Error ("VirtualAlloc commit failed.\n%s", buf);
    }
#endif
    cursize += size;
    if (cursize > hunkmaxsize)
        Sys_Error ("Hunk_Alloc overflow");

    return (void *)(membase+cursize-size);
}

int Hunk_End (void)
{

    // free the remaining unused virtual memory
#if 0
    void	*buf;

    // write protect it
    buf = VirtualAlloc (membase, cursize, MEM_COMMIT, PAGE_READONLY);
    if (!buf)
        Sys_Error ("VirtualAlloc commit failed");
#endif

    hunkcount++;
//Com_Printf ("hunkcount: %i\n", hunkcount);
    return cursize;
}

void Hunk_Free (void *base)
{
    if ( base )
#ifdef VIRTUAL_ALLOC
        VirtualFree (base, 0, MEM_RELEASE);
#else
        free (base);
#endif

    hunkcount--;
}


//===========================================================================


void Sys_Mkdir (char *path)
{
	if (mkdir (path, 0777) != -1)
		return;
	if (errno != EEXIST)
		Com_Error (ERR_FATAL, "mkdir %s: %s",path, strerror(errno));
}

char	*Sys_FindFirst (char *path, unsigned musthave, unsigned canthave)
{
    return NULL;
}

char	*Sys_FindNext (unsigned musthave, unsigned canthave)
{
    return NULL;
}

void	Sys_FindClose (void)
{
}

/*
================
Sys_Milliseconds
================
*/
int Sys_Milliseconds (void)
{
	struct timeval tp;
	struct timezone tzp;
	static int		secbase;

	gettimeofday(&tp, &tzp);

	if (!secbase)
	{
		secbase = tp.tv_sec;
		return tp.tv_usec/1000;
	}

    curtime = (tp.tv_sec - secbase)*1000 + tp.tv_usec/1000;

    return curtime;
}

/*
================
Sys_Error
================
*/
void Sys_Error (char *error, ...)
{
	va_list		argptr;
	char		string[1024];

// change stdin to non blocking
	fcntl (0, F_SETFL, fcntl (0, F_GETFL, 0) & ~FNDELAY);

	va_start (argptr,error);
	vsprintf (string,error,argptr);
	va_end (argptr);
	printf ("Fatal error: %s\n",string);

	if (!NSApp)
	{	// appkit isn't running, so don't try to pop up a panel
		exit (1);
	}
        NSRunAlertPanel (@"Fatal error",[NSString stringWithCString: string]
                         ,@"exit",NULL,NULL);
	[NSApp terminate: NULL];
        exit(1);
}

/*
================
Sys_Printf
================
*/
void	Sys_ConsoleOutput (char *text)
{
	char		*t_p;
	int			l, r;

	l = strlen(text);
	t_p = text;

// make sure everything goes through, even though we are non-blocking
	while (l)
	{
		r = write (1, t_p, l);
		if (r < 0 && errno != EINTR && errno != EAGAIN)
			break;
		if (r != l)
			sleep (0);
		if (r > 0)
		{
			t_p += r;
			l -= r;
		}
	}
}

/*
================
Sys_Quit
================
*/
void Sys_Quit (void)
{
// change stdin to blocking
	fcntl (0, F_SETFL, fcntl (0, F_GETFL, 0) & ~FNDELAY);

	if (!NSApp)
		exit (0);		// appkit isn't running

    exit (0);
}


/*
================
Sys_Init
================
*/
void Sys_Init(void)
{
    moncontrol(0);	// turn off profiling except during real Quake work

// change stdin to non blocking
     fcntl (0, F_SETFL, fcntl (0, F_GETFL, 0) | FNDELAY);
}


extern	NSWindow	*vid_window_i;

void Sys_AppActivate (void)
{
    [vid_window_i makeKeyAndOrderFront: nil];
}


/*
================
Sys_SendKeyEvents

service any pending appkit events
================
*/
void Sys_SendKeyEvents (void)
{
	NSEvent	*event;
	NSDate	*date;

	date = [NSDate date];
	do
	{
		event = [NSApp
            nextEventMatchingMask: 	0xffffffff
            untilDate:		date
            inMode:			@"NSDefaultRunLoopMode"
            dequeue:		YES];
		if (event)
			[NSApp	sendEvent: event];
	} while (event);

    // grab frame time
    sys_frame_time = Sys_Milliseconds();
}


/*
================
Sys_ConsoleInput

Checks for a complete line of text typed in at the console, then forwards
it to the host command processor
================
*/
char *Sys_ConsoleInput (void)
{
    static char text[256];
    static int used;
    static qboolean overflow;
    char ch;
    int count;

    if (!stdin_active)
        return NULL;
    while ((count = read(0, &ch, 1)) == 1) {
        if (ch == '\r')
            continue;
        if (ch == '\n') {
            text[used] = 0;
            used = 0;
            if (overflow) {
                overflow = false;
                continue;
            }
            return text;
        }
        if (used < sizeof(text) - 1)
            text[used++] = ch;
        else
            overflow = true;
    }
    if (count == 0) {
        stdin_active = false;
        if (used && !overflow) {
            text[used] = 0;
            used = 0;
            return text;
        }
    }
    return NULL;
}


/*
=============
main
=============
*/
/* Workspace may launch bundles with an unrelated working directory.
 * Keep explicit +set basedir and ordinary command-line cwd semantics intact. */
static void Sys_BundleDirectory(int argc, char **argv)
{
    char path[1024];
    char *slash;
    int i, length;

    for (i = 1; i + 2 < argc; i++)
        if (!strcmp(argv[i], "+set") && !strcmp(argv[i + 1], "basedir"))
            return;
    if (strlen(argv[0]) >= sizeof(path))
        return;
    strcpy(path, argv[0]);
    slash = strrchr(path, '/');
    if (!slash)
        return;
    *slash = 0;
    length = strlen(path);
    if (length >= 4 && !strcmp(path + length - 4, ".app"))
        if (chdir(path) < 0)
            Sys_Error("Cannot enter application bundle: %s", path);
}

void main (int argc, char **argv)
{
    int		frame = 0;
    NSAutoreleasePool *pool;
	int		oldtime, t;

    pool = [[NSAutoreleasePool alloc] init];

    Sys_BundleDirectory(argc, argv);
    Qcommon_Init (argc, argv);

    [pool release];

    oldtime = Sys_Milliseconds ();
    while (1)
    {
        pool =[[NSAutoreleasePool alloc] init];

        if (++frame > 10)
            moncontrol(1);// profile only while we do each Quake frame

		t = Sys_Milliseconds ();
        Qcommon_Frame (t - oldtime);
		oldtime = t;
        moncontrol(0);

        [pool release];
    }
}
