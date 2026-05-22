import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum AuthMode { login, register, reset }

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  AuthMode _mode = AuthMode.login;
  bool _isLoading = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final supabase = Supabase.instance.client;

    try {
      if (_mode == AuthMode.login) {
        await supabase.auth.signInWithPassword(email: email, password: password);
      } else if (_mode == AuthMode.register) {
        await supabase.auth.signUp(email: email, password: password);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Registration successful. You can now log in.')),
          );
          setState(() => _mode = AuthMode.login);
        }
      } else if (_mode == AuthMode.reset) {
        await supabase.auth.resetPasswordForEmail(email);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Password reset link sent to your email.')),
          );
          setState(() => _mode = AuthMode.login);
        }
      }
    } on AuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('An unexpected error occurred: $e'), backgroundColor: Theme.of(context).colorScheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.self_improvement_rounded, size: 80, color: theme.colorScheme.primary),
                  const SizedBox(height: 24),
                  Text(
                    _mode == AuthMode.login
                        ? 'Welcome Back'
                        : _mode == AuthMode.register
                            ? 'Create Account'
                            : 'Reset Password',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your personal AI yoga instructor.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                      fontSize: 16,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                  const SizedBox(height: 48),
                  
                  TextFormField(
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    style: GoogleFonts.inter(color: theme.colorScheme.onSurface),
                    decoration: InputDecoration(
                      labelText: 'Email',
                      prefixIcon: const Icon(Icons.email_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
                    ),
                    validator: (val) => val == null || val.isEmpty ? 'Enter an email' : null,
                  ),
                  
                  if (_mode != AuthMode.reset) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      style: GoogleFonts.inter(color: theme.colorScheme.onSurface),
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
                      ),
                      validator: (val) => val == null || val.length < 6 ? 'Min 6 characters' : null,
                    ),
                  ],
                  
                  const SizedBox(height: 32),
                  
                  FilledButton(
                    onPressed: _isLoading ? null : _submit,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 24, height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            _mode == AuthMode.login
                                ? 'Sign In'
                                : _mode == AuthMode.register
                                    ? 'Sign Up'
                                    : 'Send Reset Link',
                            style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                  ),
                  
                  const SizedBox(height: 24),
                  
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _mode == AuthMode.login ? "Don't have an account?" : "Already have an account?",
                        style: GoogleFonts.inter(color: theme.colorScheme.onSurface.withOpacity(0.6)),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _mode = _mode == AuthMode.login ? AuthMode.register : AuthMode.login;
                          });
                        },
                        child: Text(
                          _mode == AuthMode.login ? 'Sign Up' : 'Sign In',
                          style: GoogleFonts.inter(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  
                  if (_mode == AuthMode.login)
                    TextButton(
                      onPressed: () => setState(() => _mode = AuthMode.reset),
                      child: Text('Forgot Password?', style: GoogleFonts.inter()),
                    ),
                    
                  if (_mode == AuthMode.reset)
                    TextButton(
                      onPressed: () => setState(() => _mode = AuthMode.login),
                      child: Text('Back to Login', style: GoogleFonts.inter()),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
