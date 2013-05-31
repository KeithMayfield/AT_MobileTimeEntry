use Mojolicious::Lite;
use Mojo::IOLoop;
use lib 'lib';

use SOAP::Lite;
use XML::LibXML;
use WebService::Autotask;

use Data::Dumper;

use Date::Calc qw( Today Add_Delta_Days );

use Storable qw( store retrieve );

### ONE-TIME AT Password Storable ###
my $atlogin;
my $atuser;
my $atpass;

$atuser = $ENV{AT_User};
$atpass = $ENV{AT_Pass};
$atlogin = {username=>$atuser, password=>$atpass};
store $atlogin, 'atlogin';

# warn Dumper %ENV;

### Call AT Login ##
$atlogin = retrieve('atlogin');

### Autotask Subs ###
my $at_query;
my $at_create;
my $at_update;
sub atquery {
	my $query = shift;
	if ( ref $query ) {
		# This operates on a HASH-based query
		eval {
			$at_query ||= WebService::Autotask->new({username => $atlogin->{username}, password => $atlogin->{password}});
		};
		if ( local $_ = $@ ) {
			die 'Autotask Login Error!  Refresh this page to try again.';
		} else {
			return $at_query->query($query);
		}
	}
};

### Internal "Database" ###

my $techs = {
	'Stefan Adams' 		=> {email=>'stefan',	at_id=>29682885},
	'Ken Cook' 		=> {email=>'ken',	at_id=>29686791},
	'Eric Geldmacher' 	=> {email=>'ericg',	at_id=>29683611},
	'Josh Graham' 		=> {email=>'josh',	at_id=>29682788},
	'Cody Kniffen' 		=> {email=>'cody',	at_id=>29687403},
	'Keith Mayfield' 	=> {email=>'keith',	at_id=>29687410},
	'Ben Nolen' 		=> {email=>'ben',	at_id=>29683579},
	'Rob Trenholm' 		=> {email=>'rob',	at_id=>29683594}
};

my $techsreverse = {map {$techs->{$_}->{at_id} => $_} keys %$techs};



### AT API Calls ###
my $atclientlist;
my $atclientlistreverse;
my $APIClientSub = sub {
	if (((stat('atclientlist'))[9]) <= time-7200) {
		my $atclientquery;
		$atclientquery = {
			entity => 'Account',
			query => [
				{name => 'id',expressions => [{op => 'IsNotNull'}]}
			]
		};
		$atclientquery = [atquery($atclientquery)];
		$atclientlist = {map {$_->{AccountName} => $_->{id}} @$atclientquery};
		$atclientlistreverse = {map {$atclientlist->{$_} => $_} keys %$atclientlist};
		store $atclientlist, 'atclientlist';
		store $atclientlistreverse, 'atclientlistreverse';
		warn 'Client List Query -- '.gmtime(time);
	}
	else {
		$atclientlist = retrieve('atclientlist');
		$atclientlistreverse = retrieve('atclientlistreverse');
		warn 'Client List Retrieve -- '.gmtime(time);
	}
};
&$APIClientSub; 
my $clientloop = Mojo::IOLoop->recurring(7200=>$APIClientSub);

my $attickets;
my $APITicketSub = sub { 
	if (((stat('atticketlist'))[9]) <= time-7200) {
		my $offset = 30;
		my ($y, $m, $d) =  Add_Delta_Days(Today(), $offset*-1);
		my $begindate = join('/', $m, $d, $y);
		$attickets = {
			entity => 'Ticket',
			query => [
				{name => 'AssignedResourceID',expressions => [{op => 'IsNotNull'}]},
				{name => 'CreateDate',expressions => [{op => 'GreaterThan', value => $begindate}]}
			]
		};
		$attickets = [atquery($attickets)];
		store $attickets, 'atticketlist';
		warn 'Tickets Query -- '.gmtime(time);
	}
	else {
		$attickets = retrieve('atticketlist');
		warn 'Tickets Retrieve -- '.gmtime(time);
	}
};
&$APITicketSub;
my $ticketloop = Mojo::IOLoop->recurring(7200=>$APITicketSub);
### Plugins ###

plugin 'MyConfig';

plugin Config => {
	default => {
		at_uri => 'http://autotask.net/ATWS/v1_5/',
		at_proxy => 'https://webservices5.autotask.net/atservices/1.5/atws.asmx',
	},
};

plugin 'mail' => {
	from => 'helpdesk@cogentinnovators.com',
	type => 'text/plain',
	how => 'smtp',
	howargs => ['mail.charter.net'],
};

### Helpers ###

helper at => sub {
	my $self = shift;
	my $query = shift;
	return undef unless $self->session->{user};
	if ( ref $query ) {
		# This operates on a HASH-based query
		eval {
			$self->stash->{at_query} ||= WebService::Autotask->new({username => $self->session->{user}, password => $self->session->{pass}});
		};
		if ( local $_ = $@ ) {
			$self->session->{user} = $self->session->{pass} = undef;
			return $self->render_exception('Autotask Login Error!  Refresh this page to try again.');
		} else {
			return $self->stash->{at_query}->query($query);
		}
	} elsif ( $query ) {
		# This operates on a fully-formed XML-based string
		my $site = $self->config->{at_proxy};
		$site =~ s/^https?:\/\///;
		$site =~ s/\/.*$//;
		eval {
			$self->stash->{soap_query} ||= SOAP::Lite->uri($self->config->{at_uri})->on_action(sub { return join('', @_)})->proxy($self->config->{at_proxy}, credentials => ["$site:443", $site, $self->config->{at_user}, $self->config->{at_pass}]);
		};
		if ( local $_ = $@ ) {
			$self->session->{user} = $self->session->{pass} = undef;
			return $self->render_exception('Autotask Login Error!  Refresh this page to try again.');
		} else {
			return $self->stash->{soap_query}->query(SOAP::Data->value($query)->name('sXML'))->result;
		}
	}
};

### Routes ###

get '/' => 'index';

get '/login' => { # Notice no subroutine here.
	text => '<form action="#" method="post">Username: <input type="text" name="user"><br />Password: <input type="password" name="pass"><br /><input type="submit" value="login"></form>'
};

post '/login' => sub { # Notice subroutine here.
	my $self = shift;
	$self->session->{$_} = $self->param($_) for qw/user pass/;
	$self->redirect_to($self->session->{route});
} => 'postlogin';

group {
	under '/timeentry';
	get '/' => {template=>'timeentry',techs=>$techs};
	post '/sendmail' => sub {
		my $self = shift;
		my $mailto = $self->mail( 
			test    => app->mode eq 'development' ? 1 : 0, # Don't send emails during development*
			# Didn't mean to take the fun out of it for you but wanted to introduce you to some good techniques.
			# The #1 virtue of a good programmer is "laziness".  That means work your butt off now to avoid more
			# work later. The code below:
			to      => join(', ', map { "$_\@cogentinnovators.com" } grep { defined $_ } 'keith', 'liz', $techs->{$self->param('tech')}->{email}),
			# is "more complicated" than the original:
			# to      => 'keith@cogentinnovators.com, liz@cogentinnovators.com',
			# however it's more future-proof.  Just add any additional users to the list above.
			# This could definitely be improved on still, eg functions and modules.  But one step at a time.  :)
			subject => $self->param('tech')." has entered time for ".$self->param('ticket')
		);
		$self->app->log->info($mailto) if app->mode eq 'development'; # * Log it.
		
		$self->session->{'tech'}=$self->param('tech');

		# RENDER MUST BE LAST THING IN THIS POST
		
		# We have to send something back to the client.  For your debugging purposes, we're sending the entire mail body
		# back to your browser so that you can log it to the console for quick and easy inspection.
		return $self->render_text($mailto);
		# But when you're finally satisified with the mail rendering, send something more usable back to the browser:
		return $self->render_json({res=>'ok'});
		# This is an ok response that your browser can interpret.  If it gets back a res:ok then X otherwise Y.
		# Note that {res=>'ok'} is arbitrary and you can call it whatever you want -- whatever it is that your browser
		# will look for and act on.
		# You might eg tell the browser that all was good my the email was not sent because it's operating in dev mode, or
		# perhaps the mail function failed and that there was an error.  The browser, receiving this infomation, could
		# then be instructed to react accordingly.  Perhaps just a popup error message.
	};
	post '/gettickets' => sub {
		my $self = shift;
		my $attickets; 
		$attickets = retrieve('atticketlist');
#		warn Dumper($attickets);
		$self->render_json ( [ map ( {
			tickettitle => $_->{Title},
			accountname => $atclientlistreverse->{$_->{AccountID}},
			ticketnumber => $_->{TicketNumber},
			tech =>	$techsreverse->{$_->{AssignedResourceID}}
		}, @$attickets ) ] );
	};	
};

under sub { # Any routes *under* here require a "user" session value to be present.  Only way to get that set is via the "login" route.
	my $self = shift;
	return 1;
	return 1 if $self->session->{user};
	$self->session->{route} = $self->url_for;
	return $self->redirect_to('login');
};

# If you made it here, you've been "authenticated".
get '/accountlist/:mode' => {mode=>'at'} => [mode=>[qw/at soap/]] => sub { # Default mode is 'at'.  Valid modes are 'at' and 'soap'.
	my $self = shift;
	my $query;
	given ( $self->param('mode') ) {
		when ( 'at' ) {
			$query = {
				entity => 'Account',
				query => [
					{name => 'id',expressions => [{op => 'IsNotNull'}]}
				]
			};
		}
	}
	$query = [$self->at($query)];
	$self->render(template => 'acclist', query => $query);
};

get '/clientticketlist/:client/:tech/:offset/:mode' => {mode=>'at'} => [mode=>[qw/at soap/]] => sub {
	my $self = shift;
	my $clientquery;
	my $techquery;
	my ($y, $m, $d) = Add_Delta_Days(Today(), $self->param('offset')*-1);
	my $begindate = join('/', $m, $d, $y);
### Build ClientName / ID Hash ###
###  Disabled for performance  ###
#	given ( $self->param('mode') ) {
#		when ( 'at' ) {
#			$clientquery = {
#				entity => 'Account',
#				query => [
#					{name => 'id',expressions => [{op => 'IsNotNull'}]}
#				]
#			};
#		}
#	}
#	$clientquery = [$self->at($clientquery)];
#	my $accounthash;
#	$accounthash = { map { $_->{AccountName} => $_->{id}} @$clientquery };
#	warn Dumper($accounthash);
##################################
	given ( $self->param('mode') ) {
		when ( 'at' ) {
			$techquery = {
				entity => 'Ticket',
				query => [
					{name => 'AssignedResourceID',expressions => [{op => 'Equals', value => $techs->{$self->param('tech')}->{at_id}}]},
					{name => 'AccountID',expressions => [{op => 'Equals', value => $atclientlist->{$self->param('client')}}]},
					{name => 'CreateDate',expressions => [{op => 'GreaterThan', value => $begindate}]}
				]
			};
		}
	}
	$techquery = [$self->at($techquery)];
	warn Dumper($techquery);
	$self->render(template => 'clientticket', techquery => $techquery);
};

get '/ticketbegin/:ticket/:mode' => {mode=>'at'} => [mode=>[qw/at soap/]] => sub { # Default mode is 'at'.  Valid modes are 'at' and 'soap'.
	my $self = shift;
	my $query;
	given ( $self->param('mode') ) {
		when ( 'at' ) {
			$query = {entity => 'Ticket',query => [{name => 'TicketNumber',expressions => [{op => 'BeginsWith', value => $self->param('ticket')}]}]};
		}
		when ('soap' ) {
			$query = '<queryxml><entity>Ticket</entity><query><condition><field udf="true">Test UDF<expression op="equals">This Is A Test</expression></field></condition></query></queryxml>';
		}
	}
	$query = [$self->at($query)];
	warn Dumper($query);
	$self->render(template => 'at', query => $query);
};

get '/techticket/:tech/:offset/:mode' => {mode=>'at'} => [mode=>[qw/at soap/]] => sub { # Default mode is 'at'.  Valid modes are 'at' and 'soap'.
	my $self = shift;
	my $query;
	my ($y, $m, $d) =  Add_Delta_Days(Today(), $self->param('offset'));
	my $begindate = join('/', $m, $d, $y); #$m."/".$d."/".$y;
	given ( $self->param('mode') ) {
		when ( 'at' ) {
			$query = {entity => 'Ticket',query => [
				{name => 'AssignedResourceID',expressions => [{op => 'Equals', value => $techs->{$self->param('tech')}->{at_id}}]},
				{name => 'CreateDate',expressions => [{op => 'GreaterThan', value => $begindate}]}
			]};
		} 
		when ('soap' ) {
			$query = '<queryxml><entity>Ticket</entity><query><condition><field udf="true">Test UDF<expression op="equals">This Is A Test</expression></field></condition></query></queryxml>';
		}
	}
	$query = [$self->at($query)];
	warn Dumper($query);
	$self->render(template => 'gettickets', query => $query);
};

### App start ###

app->start;