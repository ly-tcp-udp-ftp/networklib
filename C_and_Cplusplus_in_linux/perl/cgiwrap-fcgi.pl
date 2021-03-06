#!/usr/bin/perl
use FCGI;
use Socket;
use FCGI::ProcManager;
sub shutdown { FCGI::CloseSocket($socket); exit; }
sub restart  { FCGI::CloseSocket($socket); &main; }
use sigtrap 'handler', \&shutdown, 'normal-signals';
use sigtrap 'handler', \&restart,  'HUP';
require 'syscall.ph';
use POSIX qw(setsid);

END()   { }
BEGIN() { }
{
    #no warnings;
    *CORE::GLOBAL::exit = sub { die "fakeexit\nrc=" . shift() . "\n"; };
};

eval q{exit};
if ($@) {
    exit unless $@ =~ /^fakeexit/;
}
&main;

sub daemonize() {
    chdir '/' or die "Can't chdir to /: $!";
    defined( my $pid = fork ) or die "Can't fork: $!";
    exit if $pid;
    setsid() or die "Can't start a new session: $!";
    umask 0;
}

sub main {
   # my $path = "/home/tiankonguse/app/C_and_Cplusplus_in_linux/perl/";
    $proc_manager = FCGI::ProcManager->new( {n_processes => 1} );
    #$socket = FCGI::OpenSocket( "127.0.0.1:9001", 10 ); #use IP sockets ""
    $socket = FCGI::OpenSocket( $path."cgiwrap-dispatch.sock", 10 ); 
    #chmod 0777, $ENV{FCGI_SOCKET_PATH};
    #use UNIX sockets - user running this script must have w access to the 'nginx' folder!!
    $request =  FCGI::Request( \*STDIN, \*STDOUT, \*STDERR, \%req_params, $socket,  &FCGI::FAIL_ACCEPT_ON_INTR );
    $proc_manager->pm_manage();
    if ($request) { request_loop() }
    FCGI::CloseSocket($socket);
}

sub request_loop {
    while ( $request->Accept() >= 0 ) {
        $proc_manager->pm_pre_dispatch();

        #processing any STDIN input from WebServer (for CGI-POST actions)
        $stdin_passthrough = '';
        { 
           # no warnings; 
            $req_len = 0 + $req_params{'CONTENT_LENGTH'}; 
        };

        print $req_params{'REQUEST_METHOD'};

        if ( ( $req_params{'REQUEST_METHOD'} eq 'POST' ) && ( $req_len != 0 ) ) {
            my $bytes_read = 0;
            while ( $bytes_read < $req_len ) {
                my $data = '';
                my $bytes = read( STDIN, $data, ( $req_len - $bytes_read ) );
                last if ( $bytes == 0 || !defined($bytes) );
                $stdin_passthrough .= $data;
                $bytes_read += $bytes;
            }
        }
        
        print  $req_params{SCRIPT_FILENAME};

        #running the cgi app
        if (
            ( -x $req_params{SCRIPT_FILENAME} ) &&    #can I execute this?
            ( -s $req_params{SCRIPT_FILENAME} ) &&    #Is this file empty?
            ( -r $req_params{SCRIPT_FILENAME} )       #can I read this file?
        ) {
            pipe( CHILD_RD,   PARENT_WR );
            pipe( PARENT_ERR, CHILD_ERR );
            my $pid = open( CHILD_O, "-|" );
            unless ( defined($pid) ) {
                print("Content-type: text/plain\r\n\r\n");
                print "Error: CGI app returned no output - Executing $req_params{SCRIPT_FILENAME} failed !\n";
                next;
            }
            $oldfh = select(PARENT_ERR);
            $|     = 1;
            select(CHILD_O);
            $| = 1;
            select($oldfh);
            if ( $pid > 0 ) {
                close(CHILD_RD);
                close(CHILD_ERR);
                print PARENT_WR $stdin_passthrough;
                close(PARENT_WR);
                $rin = $rout = $ein = $eout = '';
                vec( $rin, fileno(CHILD_O),    1 ) = 1;
                vec( $rin, fileno(PARENT_ERR), 1 ) = 1;
                $ein    = $rin;
                $nfound = 0;

                while ( $nfound = select( $rout = $rin, undef, $ein = $eout, 10 ) ) {
                    die "$!" unless $nfound != -1;
                    $r1 = vec( $rout, fileno(PARENT_ERR), 1 ) == 1;
                    $r2 = vec( $rout, fileno(CHILD_O),    1 ) == 1;
                    $e1 = vec( $eout, fileno(PARENT_ERR), 1 ) == 1;
                    $e2 = vec( $eout, fileno(CHILD_O),    1 ) == 1;

                    if ($r1) {
                        while ( $bytes = read( PARENT_ERR, $errbytes, 4096 ) ) {
                            print STDERR $errbytes;
                        }
                        if ($!) {
                            $err = $!;
                            die $!;
                            vec( $rin, fileno(PARENT_ERR), 1 ) = 0
                            unless ( $err == EINTR or $err == EAGAIN );
                        }
                    }
                    if ($r2) {
                        while ( $bytes = read( CHILD_O, $s, 4096 ) ) {
                            print $s;
                        }
                        if ( !defined($bytes) ) {
                            $err = $!;
                            die $!;
                            vec( $rin, fileno(CHILD_O), 1 ) = 0
                            unless ( $err == EINTR or $err == EAGAIN );
                        }
                    }
                    last if ( $e1 || $e2 );
                }
                close CHILD_RD;
                close PARENT_ERR;
                waitpid( $pid, 0 );
            } else {
                foreach $key ( keys %req_params ) {
                    $ENV{$key} = $req_params{$key};
                }

                # cd to the script's local directory
                if ( $req_params{SCRIPT_FILENAME} =~ /^(.*)\/[^\/] +$/ ) {
                    chdir $1; 
                }
                close(PARENT_WR);
                #close(PARENT_ERR);
                close(STDIN);
                close(STDERR);

                #fcntl(CHILD_RD, F_DUPFD, 0);
                syscall( &SYS_dup2, fileno(CHILD_RD),  0 );
                syscall( &SYS_dup2, fileno(CHILD_ERR), 2 );

                #open(STDIN, "<&CHILD_RD");
                exec( $req_params{SCRIPT_FILENAME} );
                die("exec failed");
            }
        } else {
            print("Content-type: text/plain\r\n\r\n");
            print "Error: No such CGI app - $req_params{SCRIPT_FILENAME} may not exist or is not executable by this process.\n";
        }
    }
}
