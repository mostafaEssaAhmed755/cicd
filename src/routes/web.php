<?php

use App\Jobs\SendWelcomeJob;
use Illuminate\Support\Facades\Route;

Route::get('/', function () {
    return view('welcome');
});

Route::get('test-queue', function () {
    SendWelcomeJob::dispatch();

    return 'done';
});

Route::get('link-1', function () {
    return 'Link1';
});
