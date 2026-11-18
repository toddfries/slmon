/* Drive a child on a pty. Script lines are "W text" (wait for substring),
 * "S text" (write text plus a newline), and "P n" (sleep n seconds, at
 * most 30). A bare "S" writes a newline. After the script, drain the pty
 * until stdin says QUIT, then SIGTERM. */

#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

static void
die(const char *msg)
{
	perror(msg);
	exit(1);
}

static void
wait_for(int mfd, char *acc, size_t *accn, size_t accmax, const char *want)
{
	while (strstr(acc, want) == NULL) {
		char buf[256];
		ssize_t n = read(mfd, buf, sizeof(buf));
		if (n <= 0)
			die("pty read");
		if (*accn + (size_t)n + 1 >= accmax) {
			size_t drop = (size_t)n + 1;
			if (drop > *accn)
				drop = *accn;
			memmove(acc, acc + drop, *accn - drop);
			*accn -= drop;
		}
		memcpy(acc + *accn, buf, (size_t)n);
		*accn += (size_t)n;
		acc[*accn] = '\0';
	}
}

int
main(int argc, char **argv)
{
	int mfd, status;
	pid_t pid;
	FILE *script;
	char line[1024];
	char acc[16384];
	size_t accn = 0;

	if (argc < 3) {
		fprintf(stderr, "usage: ptyfeed script command...\n");
		return 2;
	}
	script = fopen(argv[1], "r");
	if (script == NULL)
		die("fopen script");
	pid = forkpty(&mfd, NULL, NULL, NULL);
	if (pid < 0)
		die("forkpty");
	if (pid == 0) {
		execvp(argv[2], argv + 2);
		perror("execvp");
		_exit(127);
	}
	printf("PID %d\n", (int)pid);
	fflush(stdout);

	while (fgets(line, sizeof(line), script) != NULL) {
		char *nl = strchr(line, '\n');
		if (nl)
			*nl = '\0';
		if (line[0] == 'W') {
			char *want = line + 1;
			if (*want == ' ')
				want++;
			wait_for(mfd, acc, &accn, sizeof(acc), want);
		} else if (line[0] == 'S') {
			char *send = line + 1;
			if (*send == ' ')
				send++;
			if (dprintf(mfd, "%s\n", send) < 0)
				die("pty write");
		} else if (line[0] == 'P') {
			char *secs = line + 1;
			unsigned n;
			if (*secs == ' ')
				secs++;
			n = (unsigned)atoi(secs);
			if (n > 30)
				n = 30;
			if (n > 0)
				sleep(n);
		}
	}
	fclose(script);

	for (;;) {
		struct pollfd pfd[2];
		char buf[512];
		ssize_t n;

		pfd[0].fd = mfd;
		pfd[0].events = POLLIN;
		pfd[1].fd = STDIN_FILENO;
		pfd[1].events = POLLIN;
		if (poll(pfd, 2, -1) < 0) {
			if (errno == EINTR)
				continue;
			die("poll");
		}
		if (pfd[0].revents & (POLLIN | POLLHUP)) {
			n = read(mfd, buf, sizeof(buf));
			if (n > 0)
				(void)write(STDERR_FILENO, buf, (size_t)n);
			else if (n == 0)
				break;
		}
		if (pfd[1].revents & (POLLIN | POLLHUP)) {
			if (fgets(line, sizeof(line), stdin) == NULL)
				break;
			if (strncmp(line, "QUIT", 4) == 0) {
				kill(pid, SIGTERM);
				break;
			}
		}
	}
	if (waitpid(pid, &status, 0) < 0)
		die("waitpid");
	if (WIFEXITED(status))
		return WEXITSTATUS(status);
	if (WIFSIGNALED(status))
		return 128 + WTERMSIG(status);
	return 1;
}
